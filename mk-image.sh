#!/bin/bash -e

TARGET_ROOTFS_DIR=./binary

check_anima_shutdown()
{
	local architecture=${ARCH:-${RK_UBUNTU_ARCH:-arm64}} busybox=$TARGET_ROOTFS_DIR/usr/bin/busybox elf machine
	case "$architecture" in
		arm64) machine=AArch64 ;;
		armhf) machine=ARM ;;
		*) echo "ERROR: unsupported anima-shutdown architecture: $architecture" >&2; return 1 ;;
	esac
	[ -f "$busybox" ] && [ -x "$busybox" ] && [ ! -L "$busybox" ] || {
		echo "ERROR: missing installed BusyBox: $busybox; check RK_ROOTFS_PREBUILT_TOOLS_LIST" >&2; return 1;
	}
	elf=$(LC_ALL=C readelf -hl "$busybox")
	# anima-shutdown runs inside an empty 4 MiB tmpfs without shared libraries.
	if ! grep -Eq "Machine:[[:space:]]+$machine$" <<< "$elf" || grep -q INTERP <<< "$elf"; then
		echo "ERROR: SDK BusyBox must be a static $machine executable" >&2
		return 1
	fi
	[ -f "$TARGET_ROOTFS_DIR/usr/sbin/anima-shutdown" ] &&
		[ -x "$TARGET_ROOTFS_DIR/usr/sbin/anima-shutdown" ] &&
		[ ! -L "$TARGET_ROOTFS_DIR/usr/sbin/anima-shutdown" ] || {
		echo "ERROR: rootfs missing executable anima-shutdown" >&2; return 1;
	}
}

prepare_overlayfs()
(
	local dtb=${RK_KERNEL_DTB:-} bootargs option temporary usr_sec updated component
	[ -n "$dtb" ] || return 0
	case "$dtb" in
		/*) ;;
		*) dtb="${RK_SDK_DIR:-$(realpath ..)}/$dtb" ;;
	esac
	bootargs=" $(fdtget -t s "$dtb" /chosen bootargs) "
	case "$bootargs" in *' init=/sbin/anima-init '*) ;; *) return 0 ;; esac
	for option in ro rootfstype=ext4 rootflags=noload; do
		case "$bootargs" in
			*" $option "*) ;;
			*) echo "ERROR: anima-init requires $option in DTB bootargs" >&2; exit 1 ;;
		esac
	done
	case "$bootargs" in
		*' rw '*) echo "ERROR: anima-init cannot boot with rw" >&2; exit 1 ;;
	esac
	[ -x "$TARGET_ROOTFS_DIR/usr/sbin/anima-init" ] || {
		echo "ERROR: rootfs missing executable anima-init" >&2; exit 1;
	}
	for component in etc/anima/persistent.conf usr/lib/anima/persistent-config.sh usr/lib/anima/persistent-storage.sh; do
		[ -f "$TARGET_ROOTFS_DIR/$component" ] && [ ! -L "$TARGET_ROOTFS_DIR/$component" ] || {
			echo "ERROR: rootfs missing persistence component: $component" >&2; exit 1;
		}
	done
	[ -d "$TARGET_ROOTFS_DIR/overlay" ] &&
		[ -f "$TARGET_ROOTFS_DIR/etc/fstab" ] && [ ! -L "$TARGET_ROOTFS_DIR/etc/fstab" ] || {
		echo "ERROR: anima-init requires /overlay and a regular /etc/fstab" >&2; exit 1;
	}
	temporary=$(mktemp)
	trap 'rm -f "$temporary"' EXIT
	check_anima_shutdown
	# Drop /, /run, and /overlay because anima-init owns them before systemd;
	# persistent manifest mounts are appended at boot into a generated fstab.
	awk '$1 !~ /^#/ && ($2 == "/" || $2 == "/run" || $2 == "/overlay") {next} {print}' \
		"$TARGET_ROOTFS_DIR/etc/fstab" > "$temporary"
	sudo install -m 0644 "$temporary" "$TARGET_ROOTFS_DIR/etc/fstab"
	# Match /etc/.updated and /var/.updated to /usr's second-level mtime so
	# ConditionNeedsUpdate does not trigger systemd-update-done on volatile boots.
	if [ -d "$TARGET_ROOTFS_DIR/usr" ]; then
		sudo mkdir -p "$TARGET_ROOTFS_DIR/var"
		usr_sec=$(stat -c %Y "$TARGET_ROOTFS_DIR/usr")
		sudo touch -d "@$usr_sec" "$TARGET_ROOTFS_DIR/usr"
		printf '%s\n' \
			"# This file was created by systemd-update-done. Its only " \
			"# purpose is to hold a timestamp of the time this directory" \
			"# was updated. See man:systemd-update-done.service(8)." \
			"TIMESTAMP_NSEC=$((usr_sec * 1000000000))" > "$temporary"
		for updated in "$TARGET_ROOTFS_DIR/etc/.updated" "$TARGET_ROOTFS_DIR/var/.updated"; do
			sudo install -m 0644 "$temporary" "$updated"
			sudo touch -d "@$usr_sec" "$updated"
		done
	fi
)

if [ -n "${RK_ROOTFS_IMAGE:-}" ]; then
	ROOTFSIMAGE=$RK_ROOTFS_IMAGE
else
	ROOTFSIMAGE=ubuntu-$SOC-$TARGET-rootfs.img
fi

echo Making rootfs!

if [ -e "${ROOTFSIMAGE}" ]; then
	rm -f "${ROOTFSIMAGE}"
fi

COMMON_POST_BUILD="../device/rockchip/common/post-build.sh"
[ -x "$COMMON_POST_BUILD" ] || {
	echo "ERROR: Missing common post-build hook: $COMMON_POST_BUILD" >&2
	exit 1
}
sudo "$COMMON_POST_BUILD" "$(realpath "$TARGET_ROOTFS_DIR")"

# Cross-build emulators are needed by hooks, but never by the native board.
sudo rm -f -- "$TARGET_ROOTFS_DIR"/usr/bin/qemu-{arm,aarch64}-static{,~}

prepare_overlayfs

# Apparent size + maxium alignment(file_count * block_size) + maxium journal size
# Use -x / -xdev to avoid traversing any external mounts even in unexpected edge cases
IMAGE_SIZE_MB=$(( $(sudo du -x --apparent-size -sm ${TARGET_ROOTFS_DIR} | cut -f1) + \
	$(sudo find ${TARGET_ROOTFS_DIR} -xdev | wc -l) * 4 / 1024 + 64 ))

# Extra 10%
IMAGE_SIZE_MB=$(( IMAGE_SIZE_MB * 110 / 100 ))

sudo mkfs.ext4 -d "${TARGET_ROOTFS_DIR}" "${ROOTFSIMAGE}" "${IMAGE_SIZE_MB}M"

echo Rootfs Image: "${ROOTFSIMAGE}"
