#!/bin/sh
# Reassembles each <pkg>/<pkg>.spk from its committed .spk.NNN parts.
# Run from the repository root.
set -e
for p in clang ffmpeg firefox git gnome hyprland jdk kde llvm wine xfce4; do
    cat packages/$p/$p.spk.[0-9][0-9][0-9] > packages/$p/$p.spk
done