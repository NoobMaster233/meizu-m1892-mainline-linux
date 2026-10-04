# SPDX-License-Identifier: MIT
# Pure geometry validation shared with offline capacity tests. No I/O or writes.
m1892_validate_userdata_geometry()
{
	image_bytes=$1 start_sectors=$2 size_sectors=$3 logical_bytes=$4 reported_bytes=$5
	for value in "$image_bytes" "$start_sectors" "$size_sectors" "$logical_bytes" "$reported_bytes"; do
		case "$value" in ''|*[!0-9]*) return 1 ;; esac
		[ "${#value}" -le 15 ] || return 1
	done
	[ "$image_bytes" -ge 3221225472 ] && [ "$image_bytes" -le 8589934592 ] || return 1
	[ $((image_bytes % 4194304)) -eq 0 ] || return 1
	case "$logical_bytes" in 512|4096) ;; *) return 1 ;; esac
	[ "$start_sectors" -gt 0 ] && [ "$size_sectors" -gt 0 ] || return 1
	[ $((start_sectors * 512 % logical_bytes)) -eq 0 ] || return 1
	[ $((size_sectors * 512)) -eq "$reported_bytes" ] || return 1
	[ $((reported_bytes % 4096)) -eq 0 ] || return 1
	[ "$image_bytes" -lt "$reported_bytes" ] || return 1
}
