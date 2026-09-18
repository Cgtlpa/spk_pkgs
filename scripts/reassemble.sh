#!/bin/sh
# Reassembles each <pkg>/<pkg>.spk from its committed .spk.NNN parts.
# Run from the repository root.
set -e
for d in packages/[a-z]*/; do
    p="${d%/}"
    p="${p#packages/}"
    ls packages/$p/$p.spk.[0-9][0-9][0-9] >/dev/null 2>&1 || continue
    cat packages/$p/$p.spk.[0-9][0-9][0-9] > packages/$p/$p.spk
done