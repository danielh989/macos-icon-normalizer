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
    # Build the venv as the real user even under sudo, so it isn't root-owned
    # (avoids pip cache warnings and permission tangles).
    AS=""
    [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ] && AS="sudo -u $SUDO_USER"
    $AS python3 -m venv .venv
    $AS .venv/bin/pip install --quiet --upgrade pip
    $AS .venv/bin/pip install --quiet -r requirements.txt
fi

# Forward any ICON_NORMALIZER_* settings across sudo (sudo strips the env),
# so `ICON_NORMALIZER_THRESHOLD=0.90 ./run.sh` actually reaches the scanner.
FWD=""
for v in ICON_NORMALIZER_THRESHOLD ICON_NORMALIZER_SQUIRCLE ICON_NORMALIZER_CONTENT ICON_NORMALIZER_SCAN_DIRS; do
    [ -n "${!v-}" ] && FWD="$FWD $v=${!v}"
done

# Dry-run changes nothing (no admin). Everything else touches icons; root-owned
# apps need root, but only elevate if we aren't already root.
case " $* " in
    *" --dry-run "*) env $FWD .venv/bin/python normalizer.py "$@" ;;
    *)
        if [ "$(id -u)" -eq 0 ]; then env $FWD .venv/bin/python normalizer.py "$@"
        else sudo $FWD .venv/bin/python normalizer.py "$@"; fi ;;
esac
