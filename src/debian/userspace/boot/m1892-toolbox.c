// SPDX-License-Identifier: GPL-2.0-only
/*
 * Read the M1892 NON-HLOS FAT16 image without mounting it and extract only
 * the modem remoteproc firmware closure into an already-created tmpfs
 * directory.  The input is always opened read-only.
 *
 * Usage:
 *   m1892-fat16-mss-extract INPUT_BLOCK_OR_IMAGE OUTPUT_DIRECTORY
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/reboot.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define DIR_ENTRY_SIZE 32U
#define ATTR_DIRECTORY 0x10U
#define ATTR_LFN 0x0fU
#define FAT16_EOC 0xfff8U
#define MAX_SECTOR_SIZE 4096U

struct fat16 {
	int fd;
	uint32_t bytes_per_sector;
	uint32_t sectors_per_cluster;
	uint32_t reserved_sectors;
	uint32_t fat_count;
	uint32_t sectors_per_fat;
	uint32_t root_entries;
	uint32_t total_sectors;
	uint32_t root_first_sector;
	uint32_t root_sector_count;
	uint32_t data_first_sector;
	uint32_t cluster_count;
};

struct dirent83 {
	uint8_t name[11];
	uint8_t attr;
	uint16_t first_cluster;
	uint32_t size;
};

struct extraction_item {
	struct dirent83 entry;
	char output_name[32];
};

static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int pread_full(int fd, void *buffer, size_t length, uint64_t offset)
{
	uint8_t *p = buffer;

	while (length) {
		ssize_t got = pread(fd, p, length, (off_t)offset);

		if (got < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (!got) {
			errno = EIO;
			return -1;
		}
		p += got;
		length -= (size_t)got;
		offset += (uint64_t)got;
	}
	return 0;
}

static int write_full(int fd, const void *buffer, size_t length)
{
	const uint8_t *p = buffer;

	while (length) {
		ssize_t done = write(fd, p, length);

		if (done < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += done;
		length -= (size_t)done;
	}
	return 0;
}

static int is_power_of_two(uint32_t value)
{
	return value && !(value & (value - 1));
}

static int fat16_open(struct fat16 *fs, const char *input)
{
	uint8_t boot[MAX_SECTOR_SIZE];
	uint32_t total16, total32;
	uint64_t minimum_bytes;

	memset(fs, 0, sizeof(*fs));
	fs->fd = open(input, O_RDONLY | O_CLOEXEC);
	if (fs->fd < 0)
		return -1;
	if (pread_full(fs->fd, boot, sizeof(boot), 0))
		return -1;

	fs->bytes_per_sector = get_le16(boot + 11);
	fs->sectors_per_cluster = boot[13];
	fs->reserved_sectors = get_le16(boot + 14);
	fs->fat_count = boot[16];
	fs->root_entries = get_le16(boot + 17);
	total16 = get_le16(boot + 19);
	fs->sectors_per_fat = get_le16(boot + 22);
	total32 = get_le32(boot + 32);
	fs->total_sectors = total16 ? total16 : total32;

	if (fs->bytes_per_sector < 512 ||
	    fs->bytes_per_sector > MAX_SECTOR_SIZE ||
	    !is_power_of_two(fs->bytes_per_sector) ||
	    !is_power_of_two(fs->sectors_per_cluster) ||
	    !fs->reserved_sectors || !fs->fat_count ||
	    !fs->root_entries || !fs->sectors_per_fat ||
	    !fs->total_sectors) {
		errno = EINVAL;
		return -1;
	}

	fs->root_sector_count =
		(fs->root_entries * DIR_ENTRY_SIZE + fs->bytes_per_sector - 1) /
		fs->bytes_per_sector;
	fs->root_first_sector =
		fs->reserved_sectors + fs->fat_count * fs->sectors_per_fat;
	fs->data_first_sector =
		fs->root_first_sector + fs->root_sector_count;
	if (fs->data_first_sector >= fs->total_sectors) {
		errno = EINVAL;
		return -1;
	}
	fs->cluster_count =
		(fs->total_sectors - fs->data_first_sector) /
		fs->sectors_per_cluster;
	if (fs->cluster_count < 4085 || fs->cluster_count >= 65525) {
		errno = EINVAL;
		return -1;
	}

	minimum_bytes = (uint64_t)fs->total_sectors * fs->bytes_per_sector;
	fprintf(stderr,
		"fat16: bps=%" PRIu32 " spc=%" PRIu32
		" clusters=%" PRIu32 " declared-bytes=%" PRIu64 "\n",
		fs->bytes_per_sector, fs->sectors_per_cluster,
		fs->cluster_count, minimum_bytes);
	return 0;
}

static uint64_t sector_offset(const struct fat16 *fs, uint32_t sector)
{
	return (uint64_t)sector * fs->bytes_per_sector;
}

static uint64_t cluster_offset(const struct fat16 *fs, uint16_t cluster)
{
	uint32_t sector = fs->data_first_sector +
			  ((uint32_t)cluster - 2) * fs->sectors_per_cluster;

	return sector_offset(fs, sector);
}

static int fat16_next_cluster(const struct fat16 *fs, uint16_t cluster,
			      uint16_t *next)
{
	uint8_t value[2];
	uint64_t offset;

	offset = sector_offset(fs, fs->reserved_sectors) +
		 (uint64_t)cluster * 2;
	if (pread_full(fs->fd, value, sizeof(value), offset))
		return -1;
	*next = get_le16(value);
	return 0;
}

static void parse_dirent(const uint8_t *raw, struct dirent83 *entry)
{
	memcpy(entry->name, raw, sizeof(entry->name));
	entry->attr = raw[11];
	entry->first_cluster = get_le16(raw + 26);
	entry->size = get_le32(raw + 28);
}

static int valid_short_entry(const uint8_t *raw)
{
	if (raw[0] == 0x00 || raw[0] == 0xe5)
		return 0;
	if ((raw[11] & ATTR_LFN) == ATTR_LFN)
		return 0;
	if (raw[11] & 0x08)
		return 0;
	return 1;
}

static int name_is(const struct dirent83 *entry, const char expected[11])
{
	return !memcmp(entry->name, expected, 11);
}

static int find_root_entry(const struct fat16 *fs, const char expected[11],
			   struct dirent83 *result)
{
	uint8_t *root;
	size_t root_bytes =
		(size_t)fs->root_sector_count * fs->bytes_per_sector;
	uint32_t i;
	int found = -1;

	root = malloc(root_bytes);
	if (!root)
		return -1;
	if (pread_full(fs->fd, root, root_bytes,
		       sector_offset(fs, fs->root_first_sector)))
		goto out;

	for (i = 0; i < fs->root_entries; i++) {
		const uint8_t *raw = root + i * DIR_ENTRY_SIZE;
		struct dirent83 entry;

		if (raw[0] == 0x00)
			break;
		if (!valid_short_entry(raw))
			continue;
		parse_dirent(raw, &entry);
		if (name_is(&entry, expected)) {
			*result = entry;
			found = 0;
			break;
		}
	}
	if (found)
		errno = ENOENT;
out:
	free(root);
	return found;
}

static int mss_output_name(const struct dirent83 *entry,
			   char *output, size_t output_size)
{
	unsigned int b_number;

	if (name_is(entry, "MBA     MBN")) {
		snprintf(output, output_size, "mba.mbn");
		return 1;
	}
	if (name_is(entry, "MODEM   MDT")) {
		/*
		 * Linux DTS convention names the MDT header modem.mbn; the
		 * qcom MDT loader then derives modem.bXX segment names from it.
		 */
		snprintf(output, output_size, "modem.mbn");
		return 1;
	}
	if (memcmp(entry->name, "MODEM   B", 9))
		return 0;
	if (!isdigit(entry->name[9]) || !isdigit(entry->name[10]))
		return 0;
	b_number = (unsigned int)(entry->name[9] - '0') * 10U +
		   (unsigned int)(entry->name[10] - '0');
	snprintf(output, output_size, "modem.b%02u", b_number);
	return 1;
}

static int extract_file(const struct fat16 *fs,
			const struct dirent83 *entry,
			const char *output_dir, const char *output_name)
{
	char *path;
	uint8_t *buffer = NULL;
	uint16_t cluster, next;
	uint32_t remaining = entry->size;
	uint32_t walked = 0;
	size_t cluster_bytes =
		(size_t)fs->sectors_per_cluster * fs->bytes_per_sector;
	int output_fd = -1;
	int result = -1;

	if (entry->attr & ATTR_DIRECTORY) {
		errno = EISDIR;
		return -1;
	}
	if (entry->size && entry->first_cluster < 2) {
		errno = EINVAL;
		return -1;
	}
	if (asprintf(&path, "%s/%s", output_dir, output_name) < 0)
		return -1;
	output_fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
			 O_NOFOLLOW, 0644);
	if (output_fd < 0)
		goto out;
	buffer = malloc(cluster_bytes);
	if (!buffer)
		goto out;

	cluster = entry->first_cluster;
	while (remaining) {
		size_t amount = remaining < cluster_bytes ?
				remaining : cluster_bytes;

		if (cluster < 2 || cluster >= FAT16_EOC ||
		    ++walked > fs->cluster_count) {
			errno = EINVAL;
			goto out;
		}
		if (pread_full(fs->fd, buffer, amount,
			       cluster_offset(fs, cluster)) ||
		    write_full(output_fd, buffer, amount))
			goto out;
		remaining -= (uint32_t)amount;
		if (!remaining)
			break;
		if (fat16_next_cluster(fs, cluster, &next))
			goto out;
		cluster = next;
	}
	if (fsync(output_fd))
		goto out;
	fprintf(stderr, "extracted %s (%" PRIu32 " bytes)\n",
		output_name, entry->size);
	result = 0;
out:
	if (output_fd >= 0)
		close(output_fd);
	if (result)
		unlink(path);
	free(buffer);
	free(path);
	return result;
}

static int extract_mss_directory(const struct fat16 *fs, uint16_t start,
				 const char *output_dir)
{
	struct extraction_item items[64];
	uint8_t *cluster_data;
	uint16_t cluster = start, next;
	uint32_t walked = 0;
	size_t cluster_bytes =
		(size_t)fs->sectors_per_cluster * fs->bytes_per_sector;
	unsigned int mba_count = 0, mdt_count = 0, segment_count = 0;
	size_t item_count = 0;
	size_t extract_index;
	int result = -1;

	if (start < 2) {
		errno = EINVAL;
		return -1;
	}
	cluster_data = malloc(cluster_bytes);
	if (!cluster_data)
		return -1;

	for (;;) {
		size_t offset;

		if (cluster < 2 || cluster >= FAT16_EOC ||
		    ++walked > fs->cluster_count) {
			errno = EINVAL;
			goto out;
		}
		if (pread_full(fs->fd, cluster_data, cluster_bytes,
			       cluster_offset(fs, cluster)))
			goto out;

		for (offset = 0; offset < cluster_bytes;
		     offset += DIR_ENTRY_SIZE) {
			const uint8_t *raw = cluster_data + offset;
			struct dirent83 entry;
			char output_name[32];

			if (raw[0] == 0x00)
				goto complete;
			if (!valid_short_entry(raw))
				continue;
			parse_dirent(raw, &entry);
			if (!mss_output_name(&entry, output_name,
					     sizeof(output_name)))
				continue;
			if (item_count >= sizeof(items) / sizeof(items[0])) {
				errno = E2BIG;
				goto out;
			}
			items[item_count].entry = entry;
			snprintf(items[item_count].output_name,
				 sizeof(items[item_count].output_name), "%s",
				 output_name);
			item_count++;
			if (!strcmp(output_name, "mba.mbn"))
				mba_count++;
			else if (!strcmp(output_name, "modem.mbn"))
				mdt_count++;
			else
				segment_count++;
		}
		if (fat16_next_cluster(fs, cluster, &next))
			goto out;
		if (next >= FAT16_EOC)
			break;
		cluster = next;
	}

complete:
	if (mba_count != 1 || mdt_count != 1 || !segment_count) {
		fprintf(stderr,
			"incomplete MSS closure: mba=%u mdt=%u segments=%u\n",
			mba_count, mdt_count, segment_count);
		errno = ENOENT;
		goto out;
	}
	fprintf(stderr, "MSS closure complete: %u segment files\n",
		segment_count);
	for (extract_index = 0; extract_index < item_count; extract_index++) {
		if (extract_file(fs, &items[extract_index].entry, output_dir,
				 items[extract_index].output_name))
			goto out;
	}
	result = 0;
out:
	free(cluster_data);
	return result;
}

static int fat16_mss_main(int argc, char **argv)
{
	static const char image_name[11] = "IMAGE      ";
	struct fat16 fs;
	struct dirent83 image_dir;
	struct stat output_stat;
	int result = EXIT_FAILURE;

	if (argc != 3) {
		fprintf(stderr, "usage: %s INPUT OUTPUT_DIRECTORY\n", argv[0]);
		return EXIT_FAILURE;
	}
	if (stat(argv[2], &output_stat) ||
	    !S_ISDIR(output_stat.st_mode)) {
		fprintf(stderr, "output is not a directory: %s\n", argv[2]);
		return EXIT_FAILURE;
	}
	if (fat16_open(&fs, argv[1])) {
		perror("open/validate FAT16");
		return EXIT_FAILURE;
	}
	if (find_root_entry(&fs, image_name, &image_dir) ||
	    !(image_dir.attr & ATTR_DIRECTORY)) {
		perror("find IMAGE directory");
		goto out;
	}
	if (extract_mss_directory(&fs, image_dir.first_cluster, argv[2])) {
		perror("extract MSS closure");
		goto out;
	}
	result = EXIT_SUCCESS;
out:
	close(fs.fd);
	return result;
}

static int sysfs_fail(const char *phase, const char *path)
{
	int saved_errno = errno;

	fprintf(stderr,
		"SYSFS_WRITE_ERR phase=%s path=%s errno=%d message=%s\n",
		phase, path, saved_errno, strerror(saved_errno));
	return 1;
}

static int sysfs_write_main(int argc, char **argv)
{
	char *buffer;
	size_t payload_len;
	size_t write_len;
	ssize_t written;
	int fd;

	if (argc != 3) {
		fprintf(stderr, "usage: %s SYSFS_PATH VALUE\n", argv[0]);
		return 2;
	}

	payload_len = strlen(argv[2]);
	if (payload_len > 4095) {
		errno = E2BIG;
		return sysfs_fail("validate", argv[1]);
	}

	buffer = malloc(payload_len + 2);
	if (!buffer)
		return sysfs_fail("malloc", argv[1]);
	memcpy(buffer, argv[2], payload_len);
	buffer[payload_len] = '\n';
	buffer[payload_len + 1] = '\0';
	write_len = payload_len + 1;

	fd = open(argv[1], O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		free(buffer);
		return sysfs_fail("open", argv[1]);
	}
	written = write(fd, buffer, write_len);
	if (written < 0) {
		int saved_errno = errno;

		close(fd);
		free(buffer);
		errno = saved_errno;
		return sysfs_fail("write", argv[1]);
	}
	if ((size_t)written != write_len) {
		close(fd);
		free(buffer);
		errno = EIO;
		return sysfs_fail("short-write", argv[1]);
	}
	if (close(fd) < 0) {
		free(buffer);
		return sysfs_fail("close", argv[1]);
	}

	printf("SYSFS_WRITE_OK path=%s value=%s bytes=%zd errno=0\n",
	       argv[1], argv[2], written);
	free(buffer);
	return 0;
}

static int reboot_fastboot_main(int argc, char **argv)
{
	long rc;

	if (argc != 2 || strcmp(argv[1], "bootloader") != 0) {
		fprintf(stderr, "usage: %s bootloader\n", argv[0]);
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "reboot-fastboot: root privileges are required\n");
		return 1;
	}

	fprintf(stderr,
		"reboot-fastboot: syncing and requesting RESTART2(bootloader)\n");
	sync();
	sleep(1);
	rc = syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		     LINUX_REBOOT_CMD_RESTART2, "bootloader");
	if (rc < 0) {
		fprintf(stderr, "reboot-fastboot: reboot syscall failed: %s\n",
			strerror(errno));
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *program = strrchr(argv[0], '/');

	program = program ? program + 1 : argv[0];
	if (strstr(program, "sysfs-write-errno"))
		return sysfs_write_main(argc, argv);
	if (strstr(program, "reboot-fastboot"))
		return reboot_fastboot_main(argc, argv);
	if (strstr(program, "m1892-fat16-mss-extract"))
		return fat16_mss_main(argc, argv);

	fprintf(stderr,
		"unknown multicall name '%s'; expected sysfs-write-errno, "
		"reboot-fastboot, or m1892-fat16-mss-extract\n",
		program);
	return 2;
}
