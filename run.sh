#!/bin/bash
# Run the scanner straight from this folder — no system install, no daemon.
# A local .venv (Pillow + pyobjc) is created on first use.
#
#   ./run.sh --dry-run   # preview, no admin, no changes
#   ./run.sh             # apply (prompts for admin; root-owned apps need it)
#   ./run.sh --force / --revert / --squircle ...
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -x .venv/bin/python ]; then
    echo "==> Creating local .venv (Pillow + pyobjc)"
    python3 -m venv .venv
    .venv/bin/pip install --quiet --upgrade pip
    .venv/bin/pip install --quiet -r requirements.txt
fi

# Dry-run changes nothing, so it needs no admin. Everything else touches icons
# (root-owned apps need root), so elevate.
case " $* " in
    *" --dry-run "*) .venv/bin/python normalizer.py "$@" ;;
    *) sudo .venv/bin/python normalizer.py "$@" ;;
esac
