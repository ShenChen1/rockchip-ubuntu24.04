#!/bin/bash

# Per-entry transactional initializer and device identity manager.
# Expects $OVERLAY_STORAGE, $PERSISTENT, $STATE, $NEW_ROOT, emergency() from
# anima-init, and the PERSIST_* arrays populated by persistent-config.sh.

check_storage_directory()
{
	# Reject symlinks and verify same filesystem ID (%d) so storage stays on overlay ext4.
	[ -d "$1" ] && [ ! -L "$1" ] || emergency "invalid persistent directory: $1"
	[ "$(stat -c %d "$1")" = "$(stat -c %d "$OVERLAY_STORAGE")" ] || \
		emergency "persistent directory crosses filesystem: $1"
}

check_private_directory()
{
	# Admin-owned storage ancestors must remain 0:0:700 so unprivileged users
	# cannot swap directory components between boots.
	check_storage_directory "$1"
	[ "$(stat -c %u:%g:%a "$1")" = 0:0:700 ] || \
		emergency "invalid permissions for persistent directory: $1"
}

check_directory_path()
{
	# Walk rel_path component-by-component below base_dir to stop symlink traversal.
	# Usage: check_directory_path <base_dir> <rel_path> [normal|private] [check|create]
	#   normal  : forbid symlinks, allow existing dirs; mkdir uses 0755 if create
	#   private : also enforce root:root 0700 on every component; mkdir uses 0700
	#   check   : skip missing components; create : mkdir missing components
	local rest=${2#/} mode=${3:-normal} create=${4:-check} part path=$1
	[ -n "$rest" ] || return 0
	while [ -n "$rest" ]; do
		part=${rest%%/*}
		if [ "$part" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
		path=$path/$part
		[ ! -L "$path" ] || emergency "invalid directory parent: $path"
		if [ ! -e "$path" ]; then
			[ "$create" = create ] || continue
			if [ "$mode" = private ]; then mkdir -m 0700 "$path"; else mkdir -m 0755 "$path"; fi
		fi
		[ -d "$path" ] || emergency "invalid directory parent: $path"
		[ "$mode" != private ] || check_private_directory "$path"
	done
}

prepare_entry_transaction()
{
	# Stage each unpublished item in its own scratch subtree under .pending:
	#   .pending/entries/<rel>/payload  (ordinary persistent directories)
	#   .pending/identity/payload       (device machine-id + random-seed tree)
	local relative=$1
	check_directory_path "$OVERLAY_STORAGE" ".anima-persistent/.pending/$relative" private create
	PENDING=$PERSISTENT/.pending/$relative/payload
	# Only this entry's unpublished payload is disposable; its parent is root-private.
	rm -rf --one-file-system -- "$PENDING"
}

publish_entry_transaction()
{
	# Same-filesystem rename publishes one complete entry atomically. sync -f
	# flushes ext4 data and metadata before and after publication.
	local destination=$1 parent=${1%/*} cleanup=${PENDING%/*} pending_root=$PERSISTENT/.pending
	check_directory_path "$OVERLAY_STORAGE" "${parent#"$OVERLAY_STORAGE"}" private create
	sync -f "$PENDING"
	mv -T "$PENDING" "$destination"
	sync -f "$parent"
	# Ascend only within .pending so shared ancestors stay if another pending entry exists.
	while [[ "$cleanup" == "$pending_root"/* ]]; do
		rmdir "$cleanup" 2>/dev/null || break
		cleanup=${cleanup%/*}
	done
	rmdir "$pending_root" 2>/dev/null || :
}

apply_persistent_metadata()
{
	# Apply manifest mode/owner only to the newly created top-level entry; '-' keeps
	# defaults (seed preserves image metadata, overlay upper copies slot lower).
	local target=$1 path=$2 reference=${3:-}
	local mode=${PERSIST_MODE[$target]} owner=${PERSIST_OWNER[$target]}
	if [ "$mode" != - ]; then chmod "$mode" "$path"
	elif [ -n "$reference" ]; then chmod --reference="$reference" "$path"; fi
	if [ "$owner" != - ]; then chown "$owner" "$path"
	elif [ -n "$reference" ]; then chown --reference="$reference" "$path"; fi
}

initialize_persistent_entry()
{
	# Existence means published: never reseed, restore deleted files or reapply
	# metadata on a later boot. This is not an application schema migration.
	local target=$1 source=$OVERLAY_STORAGE/${PERSIST_SOURCE[$1]#/overlay/} lower=$STATE/root-ro$1
	[ ! -d "$source" ] || return 0
	prepare_entry_transaction "entries/${PERSIST_SOURCE[$target]#/overlay/}"
	if [ "${PERSIST_TYPE[$target]}" = overlay ]; then
		mkdir -m 0700 "$PENDING" "$PENDING/upper" "$PENDING/work"
		apply_persistent_metadata "$target" "$PENDING/upper" "$lower"
	else
		if [ "${PERSIST_INIT[$target]}" = seed ]; then
			cp -a "$lower" "$PENDING"
		else
			mkdir -m 0700 "$PENDING"
		fi
		apply_persistent_metadata "$target" "$PENDING"
	fi
	publish_entry_transaction "$source"
}

check_machine_id()
{
	# Expect 32 lowercase hex digits plus trailing newline (33 bytes), never all zeros.
	local file=$1 uuid
	[ -f "$file" ] && [ ! -L "$file" ] || emergency "invalid machine-id: $file"
	[ "$(stat -c %u:%g:%a "$file")" = 0:0:444 ] || emergency "invalid permissions for machine-id: $file"
	read -r uuid < "$file" || emergency "empty machine-id: $file"
	[[ "$uuid" =~ ^[0-9a-f]{32}$ && "$uuid" != 00000000000000000000000000000000 ]] && \
		[ "$(stat -c %s "$file")" = 33 ] || emergency "invalid machine-id content: $file"
}

prepare_persistent_identity()
{
	# Two-phase state machine: publish $state first, validate its files, then
	# create $marker (identity-ready).
	#   crash before mv  -> $state absent, regenerated cleanly on next boot
	#   crash after mv   -> $state reused without generating a second UUID
	#   after ready      -> missing $state/files halts boot instead of rotating ID
	local state=$PERSISTENT/state marker=$PERSISTENT/identity-ready uuid seed
	if [ -e "$marker" ] || [ -L "$marker" ]; then
		check_private_directory "$marker"
		[ -d "$state" ] || emergency "missing published identity state"
	fi
	if [ ! -e "$state" ] && [ ! -L "$state" ]; then
		prepare_entry_transaction identity
		mkdir -m 0700 "$PENDING" "$PENDING/etc" "$PENDING/var" "$PENDING/var/lib" "$PENDING/var/lib/systemd"
		read -r uuid < /proc/sys/kernel/random/uuid
		uuid=${uuid//-/}
		# Create files directly with final restrictive permissions (0444 / 0600).
		(umask 0333; printf '%s\n' "$uuid" > "$PENDING/etc/machine-id")
		(umask 077; : > "$PENDING/var/lib/systemd/random-seed")
		check_machine_id "$PENDING/etc/machine-id"
		publish_entry_transaction "$state"
	fi
	check_directory_path "$PERSISTENT" state/etc private
	check_directory_path "$PERSISTENT" state/var/lib/systemd private
	check_machine_id "$state/etc/machine-id"
	seed=$state/var/lib/systemd/random-seed
	[ -f "$seed" ] && [ ! -L "$seed" ] || emergency "invalid random seed: $seed"
	[ "$(stat -c %u:%g:%a "$seed")" = 0:0:600 ] || emergency "invalid random seed permissions: $seed"
	if [ ! -d "$marker" ]; then
		mkdir -m 0700 "$marker"
		sync -f "$PERSISTENT"
	fi
}

prepare_persistent_storage()
{
	local target
	check_directory_path "$OVERLAY_STORAGE" .anima-persistent private create
	prepare_persistent_identity
	for target in "${PERSIST_TARGETS[@]}"; do initialize_persistent_entry "$target"; done
}

mount_persistent_seed()
{
	# This file bind relies on systemd updating the seed inode in place.
	# Do not generalize it to files whose writers replace them with rename().
	local seed=$NEW_ROOT/var/lib/systemd/random-seed
	check_directory_path "$NEW_ROOT" var/lib/systemd normal create
	[ ! -L "$seed" ] || emergency "invalid random seed target: $seed"
	# Create a volatile 0600 placeholder mountpoint if the slot omits random-seed.
	[ -e "$seed" ] || (umask 077; : > "$seed")
	[ -f "$seed" ] || emergency "invalid random seed target: $seed"
	mount --bind "$PERSISTENT/state/var/lib/systemd/random-seed" "$seed"
}
