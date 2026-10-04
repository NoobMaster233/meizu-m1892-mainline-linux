// SPDX-License-Identifier: GPL-2.0-only
/*
 * Explicit M1892 mainline helper for Linux RESTART2("bootloader").
 *
 * The PM8998 PON node defines mode-bootloader = <2>.  The qcom PON reboot
 * mode driver writes that value when kernel_restart() receives "bootloader".
 * Requiring the literal argument below prevents an accidental bare-command
 * reboot during bring-up.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
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
