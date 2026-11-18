#!/usr/bin/env bash
# Release-readiness check for the radio profiles.
#
# Prints every (region, width) of the supported adapter and every fallback channel with
# its validation state and exits non-zero while any of them is not live-validated or a
# required width (1, 2, 4 and 8 MHz for AU) is missing from the table (a
# width or fallback counts as validated only by live evidence on the target device,
# never by the driver tables or an off-device test).
#
# Usage: tools/release_readiness.sh            (uses the table in the source tree)
#        HALOW_RADIO_PROFILES=<file> tools/release_readiness.sh
set -o errexit -o nounset -o pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_lib="${HALOW_LIB_DIR:-$_here/../rootfs/usr/lib/halow}"
if [ ! -f "$_lib/radio.sh" ]; then
    _lib="/usr/lib/halow"
fi

# shellcheck source=/dev/null
. "$_lib/constants.sh"
# shellcheck source=/dev/null
. "$_lib/radio.sh"

if halow_radio_release_readiness; then
    echo "RESULT: release-ready (every width and fallback is live-validated)"
    exit 0
fi
echo "RESULT: NOT release-ready (widths or fallbacks above are missing or still need live validation)"
exit 1
