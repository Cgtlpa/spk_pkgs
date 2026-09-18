#!/bin/sh
# amd-grub-setup - make the AMD GPU stack boot-ready, then update GRUB.
# Part of the spk 'amd' package (Mesa radeonsi/R600 + RADV + amdgpu DDX).
# Idempotent: safe to run multiple times. Must be run as root for a live
# system. It is also executed automatically by `spk get` via the package's
# usr/lib/spk/postinstall hook (with SPK_ROOT pointing at the install target).
#
# Env:
#   SPK_ROOT   install target prefix ("/" or empty = live system).
#              Honored so `spk get <pkg> --root DIR` configures DIR, not /.
#
# What it does (under $ROOT):
#   0) Overlays the payload's usr/ into the system (Mesa libs, amdgpu
#      modules, firmware, Xorg/Vulkan data) and records them for `spk rm`
#   1) Ensures the amdgpu modules-load entry and Xorg/Vulkan config files
#      shipped by the package are present
#   2) Runs depmod for the shipped 7.2.0 modules (and the running kernel)
#   3) Regenerates boot/grub/grub.cfg via grub-mkconfig (live system only,
#      best effort - a broken grub setup only warns)
#   4) Rebuilds the initramfs so amdgpu KMS + firmware load early
#      (live system only; for --root targets it prints what to run instead)
#
# Notes:
#   - GCN 3rd gen and newer need no kernel cmdline tweaks.
#   - Southern/Sea Islands (SI/CIK) cards that should use amdgpu instead of
#     radeon need manual cmdline opts, e.g.:
#       radeon.si_support=0 amdgpu.si_support=1
#       radeon.cik_support=0 amdgpu.cik_support=1
#     Add them to GRUB_CMDLINE_LINUX_DEFAULT in etc/default/grub, then
#     re-run this script to regenerate grub.cfg + initramfs.
set -eu

PKG_KVER="7.2.0"

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Resolve install prefix: "" means the live system.
ROOT="${SPK_ROOT:-/}"
PREFIX=""
case "$ROOT" in
    ""|"/") PREFIX="" ;;
    *) PREFIX="$(printf '%s' "$ROOT" | sed 's|/$||')" ;;
esac

GRUB_CFG="$PREFIX/boot/grub/grub.cfg"

# Payload files live under SPK_PKGDIR when run via the spk postinstall hook
# (spk isolates payloads under <root>/spk_pkgs/<pkg>); otherwise under $ROOT.
if [ -n "${SPK_PKGDIR:-}" ]; then
    USR="$SPK_PKGDIR/usr"
else
    USR="$PREFIX/usr"
fi
PAYLOAD_MODULES_LOAD="$USR/lib/modules-load.d/amdgpu.conf"
PAYLOAD_XORG_CONF="$USR/share/X11/xorg.conf.d/10-amdgpu.conf"
PAYLOAD_VULKAN_ICD="$USR/share/vulkan/icd.d/radeon_icd.json"
PAYLOAD_KO="$USR/lib/modules/$PKG_KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst"

if [ "$(id -u)" -ne 0 ] && [ -z "$PREFIX" ]; then
    die "run as root: sudo amd-grub-setup"
fi

# 0) Overlay the payload into the system. spk isolates payloads under
# <root>/spk_pkgs/<pkg>, but kernel modules, firmware, Mesa libs and
# Xorg/Vulkan data only work from their real locations. Copy - never move,
# spk still owns the payload - usr/ over the target and record every
# installed path for `spk rm` in $SPK_APPDIR/system-files. For --root
# installs everything lands under $PREFIX instead of /.
if [ -n "${SPK_PKGDIR:-}" ] && [ -d "$SPK_PKGDIR/usr" ]; then
    LISTFILE=""
    if [ -n "${SPK_APPDIR:-}" ]; then
        mkdir -p "$SPK_APPDIR" 2>/dev/null || true
        LISTFILE="$SPK_APPDIR/system-files"
        : > "$LISTFILE" 2>/dev/null || LISTFILE=""
    fi
    mkdir -p "$PREFIX/usr" 2>/dev/null || die "cannot create $PREFIX/usr (run as root?)"
    if cp -a "$SPK_PKGDIR/usr/." "$PREFIX/usr/" 2>/dev/null; then
        log "installed $SPK_PKGDIR/usr -> $PREFIX/usr"
    else
        die "cannot copy $SPK_PKGDIR/usr to $PREFIX/usr (run as root?)"
    fi
    if [ -n "$LISTFILE" ]; then
        ( cd "$SPK_PKGDIR/usr" 2>/dev/null && find . -mindepth 1 \( -type f -o -type l \) | sed 's,^\./,,' | while IFS= read -r _rel; do
            printf '%s\n' "$PREFIX/usr/$_rel"
        done >> "$LISTFILE" ) 2>/dev/null || true
    fi
    # one cache refresh for the overlaid libs
    if command -v ldconfig >/dev/null 2>&1; then
        if [ -n "$PREFIX" ]; then
            ldconfig -r "$PREFIX" 2>/dev/null || warn "ldconfig -r $PREFIX failed; run ldconfig inside the target."
        else
            ldconfig 2>/dev/null || warn "ldconfig failed; run ldconfig by hand."
        fi
    else
        warn "ldconfig not found; newly installed libs may need a manual ldconfig."
    fi
fi

# The payload carries prebuilt modules for $PKG_KVER only - a different
# booted kernel will not load them, no matter what the rest of this script
# configures.
if [ -z "$PREFIX" ]; then
    _kver="$(uname -r 2>/dev/null || true)"
    if [ -n "$_kver" ] && [ "$_kver" != "$PKG_KVER" ]; then
        warn "running kernel $_kver != prebuilt modules $PKG_KVER; boot the $PKG_KVER kernel (spk linux package) or the driver will not load."
    fi
fi

# 1) Sanity-check the files this package ships.
missing=0
for f in "$PAYLOAD_MODULES_LOAD" "$PAYLOAD_XORG_CONF" "$PAYLOAD_VULKAN_ICD" "$PAYLOAD_KO"; do
    if [ -e "$f" ]; then
        log "present: $f"
    else
        warn "missing: $f (reinstall the amd package?)"
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    warn "some package files are missing; continuing anyway."
fi

# 2) depmod so the shipped 7.2.0 modules resolve.
if command -v depmod >/dev/null 2>&1; then
    if [ -n "$PREFIX" ]; then
        if [ -d "$PREFIX/lib/modules/$PKG_KVER" ]; then
            depmod -b "$PREFIX" -a "$PKG_KVER" 2>/dev/null || depmod -b "$PREFIX" "$PKG_KVER" 2>/dev/null || warn "depmod -b $PREFIX for $PKG_KVER failed"
            log "ran depmod -b $PREFIX for $PKG_KVER"
        else
            log "no $PREFIX/lib/modules/$PKG_KVER; skipping depmod for target"
        fi
    else
        if [ -d "/lib/modules/$PKG_KVER" ]; then
            depmod -a "$PKG_KVER" 2>/dev/null || warn "depmod -a $PKG_KVER failed"
            log "ran depmod for $PKG_KVER"
        fi
        if [ -d "/lib/modules/$(uname -r)" ]; then
            depmod -a "$(uname -r)" 2>/dev/null || depmod -a || true
            log "ran depmod for $(uname -r)"
        else
            depmod -a || true
            log "ran depmod -a"
        fi
    fi
else
    warn "depmod not found; skipping."
fi

# Steps 3-4 touch the running bootloader/initramfs: only valid on the live
# system. For --root installs the files above are staged under $ROOT and the
# target's own boot must be configured from inside it.
if [ -n "$PREFIX" ]; then
    log "installed into $PREFIX: AMD config staged, not activated."
    log "to activate inside that target, run: chroot $PREFIX amd-grub-setup"
    log "done. Then reboot that system and verify: lspci -k should show amdgpu, glxinfo -B should list your AMD GPU."
    exit 0
fi

# 3) Regenerate GRUB config. Best effort only: a present-but-broken
# grub-mkconfig used to kill the whole install with its own exit code.
if command -v grub-mkconfig >/dev/null 2>&1; then
    mkdir -p "$(dirname "$GRUB_CFG")"
    if grub-mkconfig -o "$GRUB_CFG"; then
        log "regenerated $GRUB_CFG via grub-mkconfig"
    else
        rc=$?
        warn "grub-mkconfig failed (exit $rc); GRUB menu NOT regenerated - fix grub, then rerun: grub-mkconfig -o $GRUB_CFG"
    fi
elif command -v update-grub >/dev/null 2>&1; then
    if update-grub; then
        log "regenerated GRUB via update-grub"
    else
        rc=$?
        warn "update-grub failed (exit $rc); GRUB menu NOT regenerated - rerun update-grub by hand."
    fi
else
    warn "neither grub-mkconfig nor update-grub found; reinstall grub package and rerun."
fi

# 4) Rebuild initramfs so amdgpu KMS + firmware load early.
rebuilt=""
if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P && rebuilt="mkinitcpio -P"
elif command -v dracut >/dev/null 2>&1; then
    dracut --force --regenerate-all && rebuilt="dracut"
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u && rebuilt="update-initramfs -u"
elif command -v booster >/dev/null 2>&1; then
    warn "booster detected; regenerate your initramfs images manually."
fi
if [ -n "$rebuilt" ]; then
    log "rebuilt initramfs via $rebuilt"
else
    warn "no initramfs tool (mkinitcpio/dracut/update-initramfs) found; if you use an initramfs, rebuild it manually so amdgpu + firmware load early."
fi

log "done. Verify: lspci -k should show amdgpu in use; glxinfo -B and vulkaninfo should list your AMD GPU. Then reboot."
