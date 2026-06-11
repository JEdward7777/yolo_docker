#!/bin/bash
#
# entrypoint.sh - Boot code-server on top of a persistent OverlayFS root.
#
# Goal: the container's entire root filesystem is overlaid so that EVERYTHING
# written at runtime (apt installs, /usr/local binaries, /root, /config, ...)
# lands on a persistent Docker volume and survives container recreation.
#
# The subtle problem this solves:
#   OverlayFS requires that `upperdir`/`workdir` are NOT located inside
#   `lowerdir`. We want lowerdir = / (the pristine image) and the persistent
#   volume is mounted at /persist (under /). If we used `lowerdir=/` directly,
#   then upperdir=/persist/upper sits *inside* lowerdir, which violates the rule
#   and causes copy-ups to silently never reach the real volume (writes vanish
#   on container teardown).
#
# The fix:
#   A bind mount of `/` is NON-RECURSIVE: it does not carry submounts (like the
#   /persist volume, /proc, /dev, ...) into the target. So if we bind `/` to a
#   scratch dir /lower, then /lower is a faithful copy of the pristine image but
#   with an EMPTY /lower/persist (the volume submount is not pulled in). Using
#   `lowerdir=/lower` then guarantees upperdir/workdir (on the volume) are NOT
#   inside lowerdir. OverlayFS is happy and copy-ups go straight to the volume.
#
set -e

PERSIST="/persist"           # Docker volume mount (already mounted by Docker before we run)
LOWER="/lower"               # clean, non-recursive bind of / used as the overlay lower layer
UPPER="$PERSIST/upper"       # writes land here -> on the persistent volume
WORK="$PERSIST/work"
MERGED="$PERSIST/merged"

# 1. Scaffolding on the persistent volume.
mkdir -p "$UPPER" "$WORK" "$MERGED" "$LOWER"

# 2. Non-recursive bind of / -> /lower. This gives a lower layer that is the
#    pristine image WITHOUT the /persist volume (and without /proc, /sys, /dev)
#    pulled in, so upperdir/workdir are safely outside lowerdir.
if ! mountpoint -q "$LOWER"; then
    mount --bind / "$LOWER"
    # Re-assert non-recursive/private so the volume can never propagate in.
    mount --make-rprivate "$LOWER" 2>/dev/null || true
fi

# 3. Build the OverlayFS using the clean lower layer.
if ! mountpoint -q "$MERGED"; then
    mount -t overlay overlay \
        -o lowerdir="$LOWER",upperdir="$UPPER",workdir="$WORK" \
        "$MERGED"
fi

# 4. Provide the kernel API filesystems inside the merged root.
for fs in proc sys dev dev/pts; do
    mkdir -p "$MERGED/$fs"
done
mountpoint -q "$MERGED/proc"    || mount --bind /proc    "$MERGED/proc"
mountpoint -q "$MERGED/sys"     || mount --bind /sys     "$MERGED/sys"
mountpoint -q "$MERGED/dev"     || mount --bind /dev     "$MERGED/dev"
mountpoint -q "$MERGED/dev/pts" || mount --bind /dev/pts "$MERGED/dev/pts"

# 5. Networking: Docker manages /etc/resolv.conf, /etc/hosts and /etc/hostname
#    on the OUTER root. The overlay's lower layer has stale/empty copies, so DNS
#    fails inside the chroot (breaking apt installs). Bind the live files in so
#    the agent has working name resolution. These are runtime files and are
#    intentionally NOT persisted (Docker regenerates them each start).
for netfile in /etc/resolv.conf /etc/hosts /etc/hostname; do
    if [ -e "$netfile" ]; then
        # Ensure a target exists in the merged tree, then bind the live file over it.
        touch "$MERGED$netfile" 2>/dev/null || true
        mountpoint -q "$MERGED$netfile" || mount --bind "$netfile" "$MERGED$netfile"
    fi
done

echo "Agent partition initialized. Switching to persistent root..."

# 6. Switch into the merged root. chroot is sufficient here (privileged
#    container, single mount namespace); pivot_root is unnecessary because the
#    overlay correctness above is what actually makes persistence work.
exec chroot "$MERGED" "$@"
