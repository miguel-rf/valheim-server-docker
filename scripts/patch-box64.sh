#!/usr/bin/env bash
# patch-box64.sh
# Patches Box64's wrappedlibogg_private.h to expose all required Ogg functions
# for Microsoft PlayFab (libparty.so) crossplay on ARM64.

set -euo pipefail

BOX64_DIR="${1:-/build/box64}"
HEADER="$BOX64_DIR/src/wrapped/wrappedlibogg_private.h"

if [ ! -f "$HEADER" ]; then
    echo "[PATCH-BOX64] Error: $HEADER not found!" >&2
    exit 1
fi

echo "[PATCH-BOX64] Patching $HEADER for Valheim Crossplay (libparty.so)..."

# Uncomment and define missing ogg functions
sed -i 's|//GO(ogg_stream_pageout_fill,.*|GO(ogg_stream_pageout_fill, iFppi)|' "$HEADER"
sed -i 's|//GO(ogg_stream_eos,.*|GO(ogg_stream_eos, iFp)|' "$HEADER"
sed -i 's|//GO(ogg_stream_destroy,.*|GO(ogg_stream_destroy, iFp)|' "$HEADER"
sed -i 's|//GO(ogg_stream_check,.*|GO(ogg_stream_check, iFp)|' "$HEADER"
sed -i 's|//GO(ogg_sync_destroy,.*|GO(ogg_sync_destroy, iFp)|' "$HEADER"
sed -i 's|//GO(ogg_sync_check,.*|GO(ogg_sync_check, iFp)|' "$HEADER"
sed -i 's|//GO(ogg_page_version,.*|GO(ogg_page_version, iFp)|' "$HEADER"

echo "[PATCH-BOX64] Successfully applied libogg patches to Box64."
