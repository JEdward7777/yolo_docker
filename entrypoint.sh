#!/bin/bash
#
# entrypoint.sh - Boot code-server on top of a persistent OverlayFS root.
#
# Goal: the container's entire root filesystem is overlaid so that EVERYTHING
# written at runtime (apt installs, /usr/local binaries, /root, /config, etc.)
# lands on a persistent Docker volume and survives container recreation.
#
# Design (and why it differs from a naive overlay+chroot):
#
#   The persistent volume is mounted at /persist, which is OUTSIDE the overlay's
#   lower layer content we care about. The overlay uses:
#       lowerdir = /            (the pristine image, read-only)
#       upperdir = /persist/upper   (writes land here -> on the volume)
#       workdir  = /persist/work
#       merged   = /persist/merged
#
#   We then pivot_root into the merged tree. The trick that makes persistence
#   actually work: we BIND the real volume (/persist) into the merged tree
#   BEFORE pivoting, so that after the switch, /persist inside the new root is
#   the REAL volume -- not an overlay-shadowed copy of it. Because upperdir and
#   workdir were pinned (at mount time) to the real volume inodes, every copy-up
#   is written straight through to the volume.
#
#   A previous version used `lowerdir=/` while the volume itself lived at the
#   same path being overlaid, which recursively shadowed the volume and silently
#   discarded all writes on container teardown. This version avoids that.
#
set -e

PERSIST="/persist"           # where the Docker volume is mounted (outside lowerdir concerns)
UPPER="$PERSIST/upper"
WORK="$PERSIST/work"
MERGED="$PERSIST/merged"

# 1. Make sure the overlay scaffolding exists on the persistent volume.
mkdir -p "$UPPER" "$WORK" "$MERGED"

# 2. Build the OverlayFS. lowerdir=/ is the pristine image; writes go to UPPER.
#    If a previous run already mounted it (e.g. on a plain restart), skip.
if ! mountpoint -q "$MERGED"; then
    mount -t overlay overlay \
        -o lowerdir=/,upperdir="$UPPER",workdir="$WORK" \
        "$MERGED"
fi

# 3. Provide the kernel API filesystems inside the merged root.
for fs in proc sys dev dev/pts; do
    mkdir -p "$MERGED/$fs"
done
mountpoint -q "$MERGED/proc"    || mount --bind /proc    "$MERGED/proc"
mountpoint -q "$MERGED/sys"     || mount --bind /sys     "$MERGED/sys"
mountpoint -q "$MERGED/dev"     || mount --bind /dev     "$MERGED/dev"
mountpoint -q "$MERGED/dev/pts" || mount --bind /dev/pts "$MERGED/dev/pts"

# 4. CRITICAL: expose the REAL persistent volume inside the merged root, so that
#    after we switch roots, /persist still points at the actual volume (and thus
#    so do the upper/work dirs the overlay copies into).
mkdir -p "$MERGED$PERSIST"
mountpoint -q "$MERGED$PERSIST" || mount --bind "$PERSIST" "$MERGED$PERSIST"

echo "Agent partition initialized. Switching to persistent root..."

# 5. Switch into the merged root. We use chroot here (privileged container,
#    single PID namespace) which is sufficient and simpler than pivot_root for
#    this use case. The bind mounts above keep everything pointing at the volume.
exec chroot "$MERGED" "$@"
