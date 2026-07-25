#!/bin/bash
# Installs/updates the released YAFDA.app on one of Konrad's Macs over SSH.
#
#   scripts/deploy-mac.sh <ssh-host> [ssh-options...]
#   e.g. scripts/deploy-mac.sh mac-mini-pro
#        scripts/deploy-mac.sh konrad-m5-mbp.local -o HostKeyAlias=konrad-m5-mbp
#
# Pushes the stapled release app from dist/, gracefully swaps the running
# instance, relaunches, and verifies. SSH copies carry no quarantine bit so
# Gatekeeper never assesses this path; same-user `osascript`/`open` reaching
# the GUI session was verified against both target Macs on 2026-07-25.
# First install on a machine: the user must (re-)grant Accessibility and
# Microphone once - the release identity is a different TCC identity from the
# self-signed dev build, by design.
set -euo pipefail

cd "$(dirname "$0")/.."

HOST="${1:?usage: deploy-mac.sh <ssh-host> [ssh-options...]}"
shift
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" "$HOST")
APP="dist/YAFDA.app"
BUNDLE_ID="com.konradmichels.yafda"

# The app must exist and carry a notarization staple - deploying an unstapled
# build usually means release.sh did not finish.
xcrun stapler validate "$APP" >/dev/null
echo "Local $APP is stapled."

ZIP=$(mktemp /tmp/yafda-deploy.XXXXXX)
trap 'rm -f "$ZIP"' EXIT
ditto -c -k --keepParent "$APP" "$ZIP"
scp -o BatchMode=yes "$@" -q "$ZIP" "$HOST:/tmp/yafda-deploy.zip"

# Graceful swap: ask nicely, poll to zero, only then fall back to pkill - a
# hard kill can interrupt an in-flight store write.
"${SSH[@]}" '
    set -euo pipefail
    # Transition: the app was renamed Mutter -> YAFDA; quit and remove BOTH.
    # The Mutter arm can be dropped once no machine runs a Mutter build.
    for NAME in Mutter YAFDA; do
        osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
    done
    for _ in $(seq 1 15); do
        pgrep -x Mutter >/dev/null || pgrep -x YAFDA >/dev/null || break
        sleep 1
    done
    for NAME in Mutter YAFDA; do
        if pgrep -x "$NAME" >/dev/null; then
            echo "WARNING: $NAME did not quit gracefully in 15s; killing." >&2
            pkill -x "$NAME" || true
            sleep 2
        fi
    done
    rm -rf /Applications/Mutter.app /Applications/YAFDA.app
    ditto -x -k /tmp/yafda-deploy.zip /Applications/
    rm -f /tmp/yafda-deploy.zip
    open /Applications/YAFDA.app
    sleep 4
    pgrep -x YAFDA >/dev/null || { echo "FAILED: YAFDA not running after launch" >&2; exit 1; }
    RUNNING_PATH=$(ps -o command= -p "$(pgrep -x YAFDA | head -1)")
    case "$RUNNING_PATH" in
        /Applications/YAFDA.app/*) ;;
        *) echo "FAILED: running binary is $RUNNING_PATH, not /Applications" >&2; exit 1 ;;
    esac
    INSTALLED_ID=$(defaults read /Applications/YAFDA.app/Contents/Info CFBundleIdentifier)
    echo "Running: $RUNNING_PATH (bundle id $INSTALLED_ID)"
'

echo "Deployed to $HOST. First install on a machine needs a one-time"
echo "Accessibility + Microphone re-grant (the app walks through it)."
