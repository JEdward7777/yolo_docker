#!/bin/bash
set -e

VOLUME_DIR="/mnt/persistent"
UPPER="$VOLUME_DIR/upper"
WORK="$VOLUME_DIR/work"
MERGED="$VOLUME_DIR/merged"

# Ensure the overlay directory structure exists inside the assigned volume
mkdir -p "$UPPER" "$WORK" "$MERGED"

# Mount the OverlayFS (lowerdir / is the pristine linuxserver/code-server image)
mount -t overlay overlay -o lowerdir=/,upperdir="$UPPER",workdir="$WORK" "$MERGED"

# Bind mount API filesystems so the chroot environment has system access
mount --bind /proc "$MERGED/proc"
mount --bind /sys "$MERGED/sys"
mount --bind /dev "$MERGED/dev"
mount --bind /dev/pts "$MERGED/dev/pts"

echo "Agent partition initialized. Pivoting root..."

# Hand off execution to the original container command inside the new root
exec chroot "$MERGED" "$@"
