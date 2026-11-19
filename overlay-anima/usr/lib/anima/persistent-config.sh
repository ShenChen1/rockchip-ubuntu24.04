#!/bin/bash

# Manifest parser, layout/fstab conflict validator, and runtime fstab generator.
# Input manifest format (/etc/anima/persistent.conf, strictly 8 whitespace fields):
#   type    : bind | overlay
#   stage   : init (mounted pre-systemd) | systemd (mounted by generated fstab)
#   init    : empty | seed (seed only valid for bind; overlays use slot lower)
#   access  : rw | ro
#   target  : normalized absolute mount path in the rootfs
#   source  : absolute path below /overlay/ (remapped to $OVERLAY_STORAGE before pivot_root)
#   mode    : 3-digit octal (optional leading 0) or '-' (applied only at first creation)
#   owner   : uid:gid (< 4294967295) or '-' (applied only at first creation)
#
# Keep manifest declaration order separately from attributes keyed by target.
# anima-init supplies globals (STATE/OVERLAY_STORAGE/...) and emergency();
# persistent-storage.sh reads the PERSIST_* arrays populated here.
PERSIST_TARGETS=()
declare -A PERSIST_TYPE=() PERSIST_STAGE=() PERSIST_INIT=() PERSIST_ACCESS=()
declare -A PERSIST_SOURCE=() PERSIST_MODE=() PERSIST_OWNER=()

persistent_paths_overlap()
{
	# Match equal path or strict child (trailing '/' prevents /etc/net matching /etc/netplan).
	[ "$1" = "$2" ] || [[ "$1" == "$2"/* ]] || [[ "$2" == "$1"/* ]]
}

validate_persistent_path()
{
	[[ "$1" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || \
		emergency "invalid persistent path: $1"
	case "$1/" in */./*|*/../*) emergency "invalid persistent path: $1" ;; esac
}

validate_persistent_target()
{
	local path=$1 reserved
	validate_persistent_path "$path"
	for reserved in /proc /sys /dev /run /overlay /opt /etc/fstab /etc/machine-id \
		/var/lib/systemd/random-seed; do
		if persistent_paths_overlap "$path" "$reserved"; then
			emergency "reserved persistent path: $path"
		fi
	done
}

validate_persistent_source()
{
	local path=$1 reserved
	validate_persistent_path "$path"
	[[ "$path" == /overlay/* ]] || emergency "persistent source must be below /overlay: $path"
	for reserved in /overlay/.anima-volatile-root /overlay/.anima-persistent/.pending \
		/overlay/.anima-persistent/identity-ready \
		/overlay/.anima-persistent/state/etc/machine-id \
		/overlay/.anima-persistent/state/var/lib/systemd/random-seed; do
		if persistent_paths_overlap "$path" "$reserved"; then
			emergency "reserved persistent source: $path"
		fi
	done
}

validate_persistent_metadata()
{
	# Disallow SUID/SGID/sticky bits (3 octal digits) and Linux INVALID_UID/GID (-1).
	local mode=$1 owner=$2 number
	[[ "$mode" = - || "$mode" =~ ^0?[0-7]{3}$ ]] || emergency "invalid persistent permissions: $mode"
	[ "$owner" != - ] || return 0
	[[ "$owner" =~ ^[0-9]+:[0-9]+$ ]] || emergency "invalid persistent owner: $owner"
	for number in "${owner%:*}" "${owner#*:}"; do
		[ "${#number}" -le 10 ] && [ "$((10#$number))" -lt 4294967295 ] || \
			emergency "invalid persistent owner: $owner"
	done
}

validate_persistent_entry()
{
	local target=$1 source=$2 existing
	validate_persistent_target "$target"
	validate_persistent_source "$source"
	for existing in "${PERSIST_TARGETS[@]}"; do
		if persistent_paths_overlap "$target" "$existing"; then
			emergency "overlapping persistent path: $target"
		fi
		if persistent_paths_overlap "$source" "${PERSIST_SOURCE[$existing]}"; then
			emergency "overlapping persistent source: $source"
		fi
	done
}

load_persistent_config()
{
	# Treat the slot's manifest as data, never shell code. Parse every row before
	# storage initialization so a later invalid row cannot publish earlier rows.
	local config=$STATE/root-ro/$CONFIG_PATH type stage policy access target source mode owner extra
	check_directory_path "$STATE/root-ro" "${CONFIG_PATH%/*}"
	[ -f "$config" ] && [ ! -L "$config" ] || emergency "invalid persistent config: /$CONFIG_PATH"
	# Check [ -n "${type:-}" ] so a final row without a trailing newline is not dropped.
	while read -r type stage policy access target source mode owner extra || [ -n "${type:-}" ]; do
		[[ -n "${type:-}" && "$type" != \#* ]] || continue
		# Exactly 8 fields: 8th field (owner) present and 9th catch-all (extra) empty.
		[ -n "${owner:-}" ] && [ -z "${extra:-}" ] || emergency "expected eight persistent config fields"
		case "$type:$policy" in bind:empty|bind:seed|overlay:empty) ;;
			*) emergency "unsupported persistent type/init: $type/$policy" ;; esac
		case "$stage" in init|systemd) ;; *) emergency "invalid persistent stage: $stage" ;; esac
		case "$access" in rw|ro) ;; *) emergency "invalid persistent access: $access" ;; esac
		validate_persistent_entry "$target" "$source"
		validate_persistent_metadata "$mode" "$owner"
		PERSIST_TARGETS+=("$target")
		PERSIST_TYPE[$target]=$type PERSIST_STAGE[$target]=$stage PERSIST_INIT[$target]=$policy
		PERSIST_ACCESS[$target]=$access PERSIST_SOURCE[$target]=$source
		# Metadata is consumed by persistent-storage.sh during first initialization.
		# shellcheck disable=SC2034
		PERSIST_MODE[$target]=$mode PERSIST_OWNER[$target]=$owner
	done < "$config"
}

validate_base_fstab_fields()
{
	# Verify minimum syntax before normalizing the mountpoint so malformed lines
	# report the line number instead of tripping the generic ERR trap.
	local where=$1 type=$2 options=$3 line=$4
	[[ -n "$where" && "$type" =~ ^[A-Za-z0-9_.+-]+(,[A-Za-z0-9_.+-]+)*$ &&
		-n "$options" && "$options" != \#* ]] || \
		emergency "invalid base fstab at line $line: expected source, target, type and options"
}

validate_base_fstab()
{
	local fstab=$STATE/root-ro/etc/fstab device where type options rest line=0
	[ -f "$fstab" ] && [ ! -L "$fstab" ] || emergency "invalid base fstab"
	while read -r device where type options rest || [ -n "${device:-}" ]; do
		line=$((line + 1))
		[[ -n "$device" && "$device" != \#* ]] || continue
		validate_base_fstab_fields "$where" "$type" "$options" "$line"
		# swap uses non-directory targets like "none"; skip mountpoint path validation.
		[ "$type" != swap ] || continue
		# Decode fstab octal escapes before subshell so emergency() runs in PID 1;
		# avoid printf '%b' so \c/\x sequences cannot be expanded.
		where=${where//\\040/ } where=${where//\\011/$'\t'} where=${where//\\012/$'\n'}
		where=${where//\\134/\\}
		[[ "$where" == /* ]] || emergency "invalid base fstab at line $line: target must be absolute"
		# Append '.' after readlink's newline so $() does not strip trailing \n from a mountpoint name.
		where=$(readlink -m -- "$where" && printf '.') || \
			emergency "invalid base fstab at line $line: cannot normalize target"
		where=${where%$'\n.'}
		check_base_fstab_target "$where"
	done < "$fstab"
}

check_base_fstab_target()
{
	local where=$1 target
	case "$where" in /|/run|/overlay) emergency "fstab conflict with init mount: $where" ;; esac
	check_internal_fstab_conflict "$where"
	for target in /etc/fstab /etc/machine-id /var/lib/systemd/random-seed; do
		check_early_fstab_conflict "$where" "$target"
	done
	for target in "${PERSIST_TARGETS[@]}"; do
		[ "$where" != "$target" ] || emergency "fstab conflict: $target"
		if persistent_paths_overlap "$where" "${PERSIST_SOURCE[$target]}"; then
			emergency "fstab conflict with persistent source: $where"
		fi
		[ "${PERSIST_STAGE[$target]}" != init ] || check_early_fstab_conflict "$where" "$target"
	done
}

check_internal_fstab_conflict()
{
	# Protect internal mounts and storage even when the manifest is empty.
	# Unrelated /run and /overlay siblings remain available for ordinary mounts.
	local where=$1 reserved
	for reserved in /run/anima /run/initramfs /overlay/.anima-volatile-root /overlay/.anima-persistent; do
		if persistent_paths_overlap "$where" "$reserved"; then
			emergency "fstab conflict with init mount: $where"
		fi
	done
}

check_early_fstab_conflict()
{
	# A later parent mount would hide an already-mounted init-stage child.
	if [ "$1" = "$2" ] || [[ "$2" == "$1"/* ]]; then
		emergency "fstab conflict: late mount $1 hides $2"
	fi
}

validate_persistent_layout()
{
	# Pre-flight all host/storage paths before touching disk. Undeclared sibling
	# directories under /overlay are ignored so A/B slot rollbacks keep working.
	local target source lower parent
	validate_base_fstab
	for target in "${PERSIST_TARGETS[@]}"; do
		# Manifest source paths start with /overlay/, which maps to $OVERLAY_STORAGE before pivot_root.
		source=$OVERLAY_STORAGE/${PERSIST_SOURCE[$target]#/overlay/}
		lower=$STATE/root-ro$target
		check_directory_path "$STATE/root-ro" "${target#/}"
		parent=${source%/*}
		# Stripping $OVERLAY_STORAGE yields "" when source sits directly under /overlay (skipped),
		# or requires any intermediate parent subdirectories to be root-private (0700).
		check_directory_path "$OVERLAY_STORAGE" "${parent#"$OVERLAY_STORAGE"}" private
		if [ -e "$source" ] || [ -L "$source" ]; then
			check_storage_directory "$source"
			if [ "${PERSIST_TYPE[$target]}" = overlay ]; then
				check_private_directory "$source"
				check_storage_directory "$source/upper"
				check_private_directory "$source/work"
			fi
		elif [ "${PERSIST_INIT[$target]}" = seed ]; then
			[ -d "$lower" ] || emergency "missing seed directory: $target"
		fi
		if [ "${PERSIST_TYPE[$target]}" = overlay ]; then
			[ -d "$lower" ] || emergency "invalid lower directory: $target"
		fi
	done
}

persistent_mount_options()
{
	# Early mounts use /run/anima/overlay; generated fstab uses /overlay after
	# pivot_root. Rebase only the leading storage prefix, not path components.
	local target=$1 source=${PERSIST_SOURCE[$1]}
	[ -z "${2:-}" ] || source=$2/${source#/overlay/}
	if [ "${PERSIST_TYPE[$target]}" = bind ]; then
		printf 'bind,%s' "${PERSIST_ACCESS[$target]}"
	else
		printf '%s,lowerdir=%s,upperdir=%s/upper,workdir=%s/work,%s' \
			"${PERSIST_ACCESS[$target]}" "$STATE/root-ro$target" "$source" "$source" "$OVERLAY_OPTIONS"
	fi
}

generate_persistent_fstab()
{
	# Append validated manifest entries to base fstab and swap it atomically
	# into $STATE/fstab (later bind-mounted read-only onto /etc/fstab).
	local target source type options temporary=$STATE/fstab.tmp
	cp "$STATE/root-ro/etc/fstab" "$temporary"
	printf '\n# Anima persistent mounts\n' >> "$temporary"
	for target in "${PERSIST_TARGETS[@]}"; do
		source=${PERSIST_SOURCE[$target]} type=none
		options=$(persistent_mount_options "$target")
		# noauto records already-active init mounts so systemd tracks stop ordering
		# without remounting. Explicit dependencies cover paths embedded inside -o.
		[ "${PERSIST_STAGE[$target]}" != init ] || options+=,noauto
		options+=,x-systemd.requires-mounts-for=/overlay
		if [ "${PERSIST_TYPE[$target]}" = overlay ]; then
			source=overlay type=overlay
			options+=,x-systemd.requires-mounts-for=$STATE/root-ro
		fi
		printf '%s %s %s %s 0 0\n' "$source" "$target" "$type" "$options" >> "$temporary"
	done
	chmod 0644 "$temporary"
	mv -T "$temporary" "$STATE/fstab"
}

mount_persistent_paths()
{
	# Ensure every declared target dir exists in NEW_ROOT (even systemd-stage
	# bind+empty entries), then mount init-stage entries before systemd starts.
	local target source options
	for target in "${PERSIST_TARGETS[@]}"; do
		check_directory_path "$NEW_ROOT" "${target#/}" normal create
		[ "${PERSIST_STAGE[$target]}" = init ] || continue
		source=$OVERLAY_STORAGE/${PERSIST_SOURCE[$target]#/overlay/}
		if [ "${PERSIST_TYPE[$target]}" = bind ]; then
			mount --bind "$source" "$NEW_ROOT$target"
			# Restrict this bind view, not the shared ext4 superblock or other entries.
			[ "${PERSIST_ACCESS[$target]}" != ro ] || mount -o remount,bind,ro "$NEW_ROOT$target"
		else
			options=$(persistent_mount_options "$target" "$OVERLAY_STORAGE")
			mount -t overlay overlay -o "$options" "$NEW_ROOT$target"
		fi
	done
}
