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
#   3) Bootloader: AMD needs no cmdline changes - the config is never
#      touched (a blind regen once left systems in grub rescue)
#   4) Rebuilds the initramfs so amdgpu KMS + firmware load early, but only
#      when a rebuild tool exists
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
    for _sub in usr etc; do
        [ -d "$SPK_PKGDIR/$_sub" ] || continue
        # never overlay the C library, loader, compiler runtimes or
        # interactive line-editing libs: the system already has them, and
        # shadowing them with bundled copies breaks unrelated binaries
        # (segfaults / GLIBC_* version errors system-wide).
        _flist="$(mktemp 2>/dev/null || printf '%s/spk-overlay.%s.tmp' "${TMPDIR:-/tmp}" "$$")"
        [ -n "$_flist" ] || die "cannot create temp file (mktemp missing and TMPDIR unwritable)"
        if ( cd "$SPK_PKGDIR/$_sub" 2>/dev/null && find . -mindepth 1 \( -type f -o -type l \) | sort > "$_flist" ) 2>/dev/null; then
            _copied=0
            _lastdir=""
            while IFS= read -r _rel; do
                _rel="${_rel#./}"
                _bn="${_rel##*/}"
                case "$_bn" in
                    ld-linux*|libc.so*|libc-[0-9]*|libm.so*|libpthread*|libdl.so*|librt.so*|libresolv*|libutil.so*|libnsl*|libnss_*|libcrypt.so*|libthread_db*|libgcc_s*|libstdc++*|libgomp*|libmemusage*|libpcprofile*|libBrokenLocale*|libtinfo*|libncurses*|libreadline*|libhistory*) continue ;;
                esac
                _dir="${_rel%/*}"
                [ "$_dir" = "$_rel" ] && _dir="."
                if [ "$_dir" != "$_lastdir" ]; then
                    mkdir -p "$PREFIX/$_sub/$_dir" 2>/dev/null || die "cannot create $PREFIX/$_sub/$_dir (run as root?)"
                    _lastdir="$_dir"
                fi
                cp -a "$SPK_PKGDIR/$_sub/$_rel" "$PREFIX/$_sub/$_rel" 2>/dev/null || die "cannot copy $_rel to $PREFIX/$_sub (run as root?)"
                _copied=$((_copied + 1))
                if [ -n "$LISTFILE" ]; then
                    printf '%s\n' "$PREFIX/$_sub/$_rel" >> "$LISTFILE" 2>/dev/null || true
                fi
            done < "$_flist"
            log "installed $_copied file(s) $SPK_PKGDIR/$_sub -> $PREFIX/$_sub"
        else
            warn "cannot list $SPK_PKGDIR/$_sub; skipping overlay of it (reinstall the package?)"
        fi
        rm -f "$_flist" 2>/dev/null || true
    done
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

# amdgpu/radeon are in-tree kernel modules, so they always match the booted
# kernel - no version check needed (unlike the out-of-tree nvidia blobs).

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

# 3) Bootloader: AMD needs no kernel cmdline changes, so never touch the
# bootloader config here - a blind grub-mkconfig regen once left systems in
# grub rescue. Just report what was found.
if [ -f "$GRUB_CFG" ]; then
    log "AMD needs no bootloader changes; leaving $GRUB_CFG alone."
else
    log "no $GRUB_CFG; nothing to do for the bootloader."
fi

# 4) Rebuild initramfs so amdgpu KMS + firmware load early - but only when
# something can actually rebuild it. Silen boots a prebuilt initramfs with
# no rebuild tool on target; there the in-tree driver + firmware already
# present are enough to get a picture.
_uses_initrd=""
if grep -q -E '^[[:space:]]*initrd[[:space:]]' "$GRUB_CFG" 2>/dev/null; then
    _uses_initrd="1"
else
    for _ird in "$PREFIX"/boot/initramfs.* "$PREFIX"/boot/initrd* "$PREFIX"/initramfs.* ; do
        [ -f "$_ird" ] && { _uses_initrd="1"; break; }
    done
fi
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
elif [ -n "$_uses_initrd" ]; then
    warn "no initramfs tool found but boot uses an initrd; rebuild the initramfs when you can."
else
    log "no initramfs in boot config; nothing to rebuild."
fi

log "done. Verify: lspci -k should show amdgpu in use; glxinfo -B and vulkaninfo should list your AMD GPU. Then reboot."
