#!/bin/sh
# spk postinstall for sddm: select sddm as the display manager and enable it.
# Never fails the install - every step is best-effort with a message.
set -eu

if [ "${SPK_USER_MODE:-0}" = "1" ]; then
    echo "sddm postinstall: --user install detected; a display manager needs a system-wide install, skipping."
    exit 0
fi

ROOT="${SPK_ROOT:-/}"
PREFIX=""
case "$ROOT" in
    ""|"/") PREFIX="" ;;
    *) PREFIX="$(printf '%s' "$ROOT" | sed 's|/$||')" ;;
esac

CONF="$PREFIX/etc/conf.d/display-manager"
# Gentoo ships DISPLAYMANAGER="xdm" as a placeholder (the classic XDM is not
# installed); take over empty/placeholder values, respect real choices.
if [ -f "$CONF" ]; then
    if grep -q '^DISPLAYMANAGER=' "$CONF" 2>/dev/null; then
        _cur="$(sed -n 's/^DISPLAYMANAGER="\?\([^"]*\)"\?/\1/p' "$CONF" 2>/dev/null | head -n 1)"
        case "$_cur" in
            ""|xdm|sddm)
                sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="sddm"/' "$CONF" 2>/dev/null || true
                echo "sddm postinstall: set DISPLAYMANAGER=sddm in $CONF."
                ;;
            *)
                echo "sddm postinstall: DISPLAYMANAGER is already '$_cur', leaving your choice alone."
                ;;
        esac
    else
        printf 'DISPLAYMANAGER="sddm"\n' >> "$CONF" 2>/dev/null || true
        echo "sddm postinstall: set DISPLAYMANAGER=sddm in $CONF."
    fi
else
    mkdir -p "$PREFIX/etc/conf.d" 2>/dev/null || true
    if printf 'DISPLAYMANAGER="sddm"\n' > "$CONF" 2>/dev/null; then
        echo "sddm postinstall: set DISPLAYMANAGER=sddm in $CONF."
    else
        echo "sddm postinstall: warning: cannot write $CONF." >&2
    fi
fi

if [ -z "$PREFIX" ]; then
    if command -v rc-update >/dev/null 2>&1; then
        if rc-update add xdm default 2>/dev/null; then
            echo "sddm postinstall: enabled xdm (sddm) for next boot."
        else
            echo "sddm postinstall: warning: could not enable xdm - run by hand: rc-update add xdm default" >&2
        fi
    else
        echo "sddm postinstall: note: no rc-update found; enable the xdm service of your init to start sddm at boot."
    fi
    echo "sddm postinstall: needs xorg-server installed (spk get xorg-server) and a reboot."
else
    echo "sddm postinstall: staged under $PREFIX; inside the target run: rc-update add xdm default"
fi
exit 0
