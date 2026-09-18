#!/bin/sh
# nvidia-grub-setup - blacklist nouveau/nova, enable nvidia, update GRUB.
# Part of the spk 'nvidia' (595 series) and 'nvidia-legacy' (580 series) packages.
# Idempotent: safe to run multiple times. Must be run as root for a live
# system. It is also executed automatically by `spk get` via the package's
# usr/lib/spk/postinstall hook (with SPK_ROOT pointing at the install target).
#
# Env:
#   SPK_ROOT   install target prefix ("/" or empty = live system).
#              Honored so `spk get <pkg> --root DIR` configures DIR, not /.
#
# What it does (under $ROOT):
#   0) Overlays the payload's usr/ and etc/ into the system (libs, kernel
#      modules, firmware, Xorg/udev data) and records them for `spk rm`
#   1) Writes etc/modprobe.d/nvidia.conf (blacklist nouveau/nova + nvidia opts)
#   2) On grub-mkconfig-managed systems: ensures etc/default/grub
#      GRUB_CMDLINE_LINUX_DEFAULT contains:
#        nvidia-drm.modeset=1 nvidia-drm.fbdev=1 modprobe.blacklist=nouveau,nova_core,nova_drm
#   3) Runs depmod for every shipped kernel release (and the running kernel)
#   4) Bootloader cmdline: regenerates grub.cfg via grub-mkconfig where it
#      manages the config, otherwise patches a static grub.cfg's `linux`
#      lines directly (Silen) - never a blind regen (that caused grub rescue)
#   5) Tries to rebuild the initramfs so the blacklist takes effect early,
#      but only when a rebuild tool exists (live system only; for --root
#      targets it prints what to run instead)
set -eu

WANT_PARAMS="nvidia-drm.modeset=1 nvidia-drm.fbdev=1 modprobe.blacklist=nouveau,nova_core,nova_drm"
PKG_KVERS="7.2.0 7.2.4-zen2-1-zen"

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

MODPROBE_CONF="$PREFIX/etc/modprobe.d/nvidia.conf"
GRUB_DEFAULT="$PREFIX/etc/default/grub"
GRUB_CFG="$PREFIX/boot/grub/grub.cfg"

if [ "$(id -u)" -ne 0 ] && [ -z "$PREFIX" ]; then
    die "run as root: sudo nvidia-grub-setup"
fi

# 0) Overlay the payload into the system. spk isolates payloads under
# <root>/spk_pkgs/<pkg>, but kernel modules, firmware, Xorg/udev data and
# GL/Vulkan libs only work from their real locations - the loader, modprobe
# and Xorg never look inside the payload (this is why nvidia-smi used to
# fail with "couldn't find libnvidia-ml.so"). Copy - never move, spk still
# owns the payload - usr/ and etc/ over the target and record every
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
    # one cache refresh for the overlaid libs (/usr/lib works without it
    # too, but only the cache covers every loader lookup)
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

# The payload carries prebuilt modules for $PKG_KVERS only - any other
# booted kernel will not load them, no matter what the rest of this script
# configures.
if [ -z "$PREFIX" ]; then
    _kver="$(uname -r 2>/dev/null || true)"
    case " $PKG_KVERS " in
        *" $_kver "*) ;;
        *) warn "running kernel ${_kver:-unknown} not covered by prebuilt modules ($PKG_KVERS); the driver will not load on this kernel." ;;
    esac
fi

# 1) modprobe blacklist + nvidia options (early-KMS safe, survives updates).
mkdir -p "$PREFIX/etc/modprobe.d"
cat > "$MODPROBE_CONF" <<'EOF'
# Generated by nvidia-grub-setup (spk nvidia / nvidia-legacy).
# Nouveau and the new NOVA (nova_core/nova_drm) drivers conflict with the
# proprietary NVIDIA driver. Blacklist them and load nvidia instead.
blacklist nouveau
blacklist nova_core
blacklist nova_drm
alias nouveau off
alias nova_core off
alias nova_drm off
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
options nvidia-drm modeset=1 fbdev=1
EOF
chmod 644 "$MODPROBE_CONF"
log "wrote $MODPROBE_CONF"
# removing the package must un-blacklist nouveau again - track this file for
# `spk rm` too (harmless if LISTFILE is unset, e.g. on manual re-runs)
if [ -n "${LISTFILE:-}" ]; then
    printf '%s\n' "$MODPROBE_CONF" >> "$LISTFILE" 2>/dev/null || true
fi

# 2) grub-mkconfig-managed systems (/etc/default/grub exists): patch the
# defaults idempotently. Static grub.cfg systems (Silen) are handled in
# step 4 below; anything else is reported there too.
if [ -f "$GRUB_DEFAULT" ]; then
    # date is missing on truly minimal systems - fall back to the pid so a
    # missing date can never fail the install (the backup name just carries
    # no timestamp then).
    stamp="$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'no-date-%s' "$$")"
    cp -a "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak.$stamp"
    # Ensure the key exists.
    if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT"; then
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$WANT_PARAMS" >> "$GRUB_DEFAULT"
        log "added GRUB_CMDLINE_LINUX_DEFAULT to $GRUB_DEFAULT"
    else
        # Append each wanted param only if missing. Operate on a temp copy.
        # mktemp is missing on truly minimal systems - without this fallback
        # the script used to die here with 127 (command not found) AFTER the
        # grub file was already patched. A pid-named file is good enough.
        tmp="$(mktemp 2>/dev/null || printf '%s/nvidia-grub-setup.%s.tmp' "${TMPDIR:-/tmp}" "$$")"
        [ -n "$tmp" ] || die "cannot create temp file (mktemp missing and TMPDIR unwritable)"
        cp "$GRUB_DEFAULT" "$tmp"
        # Extract current value of GRUB_CMDLINE_LINUX_DEFAULT (without quotes).
        current="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\?\([^"]*\)"\?/\1/p' "$tmp" | head -n 1)"
        updated="$current"
        for p in $WANT_PARAMS; do
            case " $updated " in
                *" $p "*) ;;
                *) updated="$updated $p" ;;
            esac
        done
        # Trim leading space.
        updated="$(printf '%s' "$updated" | sed 's/^ *//')"
        # Escape for sed replacement.
        esc_updated="$(printf '%s' "$updated" | sed 's/[&/\]/\\&/g')"
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="'"$esc_updated"'"/' "$tmp"
        if cmp -s "$tmp" "$GRUB_DEFAULT"; then
            log "$GRUB_DEFAULT already contains NVIDIA params; no change."
        else
            cp "$tmp" "$GRUB_DEFAULT"
            log "patched $GRUB_DEFAULT:"
            grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" || true
        fi
        rm -f "$tmp"
    fi
    # Show effective cmdline for verification.
    log "effective: $(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" || echo '(missing)')"
fi

# 3) depmod for every kernel release this payload ships modules for, plus
# the running kernel on live systems.
if command -v depmod >/dev/null 2>&1; then
    for _kv in $PKG_KVERS; do
        if [ -n "$PREFIX" ]; then
            if [ -d "$PREFIX/lib/modules/$_kv" ]; then
                depmod -b "$PREFIX" -a "$_kv" 2>/dev/null || depmod -b "$PREFIX" "$_kv" 2>/dev/null || warn "depmod -b $PREFIX for $_kv failed"
                log "ran depmod -b $PREFIX for $_kv"
            else
                log "no $PREFIX/lib/modules/$_kv; skipping depmod for target"
            fi
        else
            if [ -d "/lib/modules/$_kv" ]; then
                depmod -a "$_kv" 2>/dev/null || warn "depmod -a $_kv failed"
                log "ran depmod for $_kv"
            fi
        fi
    done
    if [ -z "$PREFIX" ]; then
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

# 4) Bootloader kernel cmdline. grub-mkconfig-managed systems were handled
# in step 2 (defaults file); regenerating there happens below, live only.
# Static grub.cfg systems (Silen writes its grub.cfg by hand) get their
# `linux` boot lines patched directly - NEVER run grub-mkconfig on those:
# it replaces the static config with a probed one and can leave the system
# in grub rescue.
if [ -f "$GRUB_DEFAULT" ]; then
    if [ -z "$PREFIX" ]; then
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
    else
        log "GRUB defaults staged under $PREFIX; regenerate inside the target (chroot $PREFIX nvidia-grub-setup)."
    fi
elif [ -f "$GRUB_CFG" ] && ! grep -q -E "grub-mkconfig|DO NOT EDIT THIS FILE" "$GRUB_CFG" 2>/dev/null; then
    # static config: append our params to every `linux` boot line, idempotently
    if ! command -v awk >/dev/null 2>&1; then
        warn "awk not found; cannot patch $GRUB_CFG - add to its linux line(s) by hand: $WANT_PARAMS"
    else
        _nlinux="$(grep -c '^[[:space:]]*linux[[:space:]]' "$GRUB_CFG" 2>/dev/null || true)"
        if [ "$_nlinux" = "0" ]; then
            warn "$GRUB_CFG has no linux boot lines; add by hand: $WANT_PARAMS"
        else
            stamp="$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'no-date-%s' "$$")"
            cp -a "$GRUB_CFG" "$GRUB_CFG.bak.$stamp" 2>/dev/null || warn "cannot back up $GRUB_CFG; continuing."
            tmp="$(mktemp 2>/dev/null || printf '%s/nvidia-grub-setup.%s.tmp' "${TMPDIR:-/tmp}" "$$")"
            if [ -z "$tmp" ]; then
                warn "cannot create temp file; add to $GRUB_CFG linux line(s) by hand: $WANT_PARAMS"
            elif awk -v params="$WANT_PARAMS" '
                /^[[:space:]]*linux[[:space:]]/ {
                    line = $0
                    n = split(params, want, " ")
                    for (i = 1; i <= n; i++)
                        if (index(" " line " ", " " want[i] " ") == 0)
                            line = line " " want[i]
                    print line
                    next
                }
                { print }
            ' "$GRUB_CFG" > "$tmp" 2>/dev/null; then
                if cmp -s "$tmp" "$GRUB_CFG"; then
                    log "$GRUB_CFG already contains NVIDIA params; no change."
                elif [ "$(grep -c '^[[:space:]]*linux[[:space:]]' "$tmp" 2>/dev/null || true)" = "$_nlinux" ]; then
                    if cat "$tmp" > "$GRUB_CFG" 2>/dev/null; then
                        log "patched $GRUB_CFG:"
                        grep '^[[:space:]]*linux[[:space:]]' "$GRUB_CFG" || true
                    else
                        warn "could not write $GRUB_CFG; add by hand: $WANT_PARAMS"
                    fi
                else
                    warn "refusing to write $GRUB_CFG (linux lines changed shape); add by hand: $WANT_PARAMS"
                fi
            else
                warn "could not patch $GRUB_CFG; add to its linux line(s) by hand: $WANT_PARAMS"
            fi
            rm -f "$tmp" 2>/dev/null || true
        fi
    fi
elif [ -f "$GRUB_CFG" ]; then
    warn "$GRUB_CFG looks grub-mkconfig-managed but $GRUB_DEFAULT is missing; regenerate it by hand."
else
    warn "no GRUB config found ($GRUB_CFG missing and no $GRUB_DEFAULT); add to your bootloader by hand: $WANT_PARAMS"
fi

# Only file edits happen above, so they are safe under --root too. Rebuilding
# an initramfs or regenerating grub for real must happen inside the target.
if [ -n "$PREFIX" ]; then
    log "installed into $PREFIX: payload, modprobe and bootloader config staged."
    log "if that target rebuilds its initramfs with mkinitcpio/dracut, chroot in and rerun this script there."
    log "then reboot it and verify: cat /proc/cmdline should show nvidia-drm.modeset=1 and modprobe.blacklist; lsmod should show nvidia, not nouveau."
    exit 0
fi

# 5) Rebuild initramfs so nouveau stays out of early boot - but only when
# something can actually rebuild it. Silen boots a prebuilt initramfs with
# no rebuild tool on target, and there the kernel cmdline blacklist patched
# above already covers early boot.
_uses_initrd=""
if grep -q -E '^[[:space:]]*initrd[[:space:]]' "$GRUB_CFG" 2>/dev/null; then
    _uses_initrd="1"
else
    for _ird in /boot/initramfs.* /boot/initrd* /initramfs.* ; do
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
    warn "no initramfs tool found but boot uses an initrd; the kernel cmdline blacklist (patched above) still covers early boot - rebuild the initramfs when you can."
else
    log "no initramfs in boot config; nothing to rebuild."
fi

log "done. Verify: cat /proc/cmdline should show nvidia-drm.modeset=1 and modprobe.blacklist; lsmod should show nvidia, not nouveau. Then reboot."
