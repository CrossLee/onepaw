#!/bin/bash
# Headless Finder-layout regression: no signing credentials, app launch, or install.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BACKGROUND="$PROJECT_DIR/Resources/Installer/DMGBackground.png"
LAYOUT_SCRIPT="$PROJECT_DIR/scripts/dmg-layout.py"
VENDOR_DIR="$PROJECT_DIR/scripts/vendor"
DS_STORE_WHEEL="$VENDOR_DIR/ds_store-1.3.1-py3-none-any.whl"
MAC_ALIAS_WHEEL="$VENDOR_DIR/mac_alias-2.2.2-py3-none-any.whl"
PYTHONPATH_VALUE="$DS_STORE_WHEEL:$MAC_ALIAS_WHEEL"
PYTHON_BIN="$(/usr/bin/xcrun --find python3)"

fail() { echo "FAIL: $*" >&2; exit 1; }

/bin/mkdir -p "$PROJECT_DIR/.build"
TEST_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/.build/onepaw-dmg-layout-tests.XXXXXX")"
WORK_DIR="$TEST_DIR/work"
ROOT_DIR="$WORK_DIR/root"
MOUNT_DIR="$WORK_DIR/mount"
RW_DMG="$WORK_DIR/layout.dmg"
FINAL_DMG="$WORK_DIR/layout-final.dmg"
MOUNTED=false

cleanup() {
    if [[ "$MOUNTED" == true ]]; then
        /usr/bin/hdiutil detach -quiet "$MOUNT_DIR" >/dev/null 2>&1 \
            || /usr/bin/hdiutil detach -force -quiet "$MOUNT_DIR" >/dev/null 2>&1 \
            || true
    fi
    if [[ "$WORK_DIR" == "$TEST_DIR/work" && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
        /bin/rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

[[ -x "$PYTHON_BIN" ]] || fail "Xcode Python is unavailable"
[[ -f "$BACKGROUND" && ! -L "$BACKGROUND" ]] || fail "approved DMG background is missing"
[[ -f "$LAYOUT_SCRIPT" && ! -L "$LAYOUT_SCRIPT" ]] || fail "DMG layout helper is missing"

EXPECTED_DS_STORE_SHA="fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5"
EXPECTED_MAC_ALIAS_SHA="504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd"
[[ "$(/usr/bin/shasum -a 256 "$DS_STORE_WHEEL" | /usr/bin/awk '{ print $1 }')" == "$EXPECTED_DS_STORE_SHA" ]] \
    || fail "vendored ds_store wheel checksum changed"
[[ "$(/usr/bin/shasum -a 256 "$MAC_ALIAS_WHEEL" | /usr/bin/awk '{ print $1 }')" == "$EXPECTED_MAC_ALIAS_SHA" ]] \
    || fail "vendored mac_alias wheel checksum changed"

WIDTH="$(/usr/bin/sips -g pixelWidth "$BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
HEIGHT="$(/usr/bin/sips -g pixelHeight "$BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ { print $2 }')"
DPI_WIDTH="$(/usr/bin/sips -g dpiWidth "$BACKGROUND" 2>/dev/null | /usr/bin/awk '/dpiWidth:/ { print $2 }')"
DPI_HEIGHT="$(/usr/bin/sips -g dpiHeight "$BACKGROUND" 2>/dev/null | /usr/bin/awk '/dpiHeight:/ { print $2 }')"
[[ "$WIDTH" == 1586 && "$HEIGHT" == 992 ]] || fail "DMG background is not 1586x992"
[[ "$DPI_WIDTH" == 144.000 && "$DPI_HEIGHT" == 144.000 ]] || fail "DMG background is not 144 dpi"

/bin/mkdir -p "$ROOT_DIR/.background" "$ROOT_DIR/一爪.app" "$MOUNT_DIR"
/bin/cp -X "$BACKGROUND" "$ROOT_DIR/.background/DMGBackground.png"
/bin/ln -s /Applications "$ROOT_DIR/Applications"

/usr/bin/hdiutil create \
    -quiet \
    -volname 一爪 \
    -fs HFS+ \
    -nospotlight \
    -srcfolder "$ROOT_DIR" \
    -ov \
    -format UDRW \
    "$RW_DMG"

MOUNTED=true
/usr/bin/hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse \
    -mountpoint "$MOUNT_DIR" \
    "$RW_DMG" >/dev/null
PYTHONPATH="$PYTHONPATH_VALUE" "$PYTHON_BIN" "$LAYOUT_SCRIPT" write "$MOUNT_DIR"
PYTHONPATH="$PYTHONPATH_VALUE" "$PYTHON_BIN" "$LAYOUT_SCRIPT" verify "$MOUNT_DIR"

/bin/rm -rf -- \
    "$MOUNT_DIR/.DocumentRevisions-V100" \
    "$MOUNT_DIR/.Spotlight-V100" \
    "$MOUNT_DIR/.Trashes" \
    "$MOUNT_DIR/.fseventsd"
/usr/bin/find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -type f -name '._*' -delete
/bin/sync
/usr/bin/hdiutil detach -quiet "$MOUNT_DIR"
MOUNTED=false

/usr/bin/hdiutil convert \
    -quiet \
    "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$FINAL_DMG"
[[ "$(/usr/bin/hdiutil imageinfo -format "$FINAL_DMG")" == UDZO ]] \
    || fail "fixture DMG is not compressed UDZO"

MOUNTED=true
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$FINAL_DMG" >/dev/null

ROOT_ENTRIES="$(/usr/bin/find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; | LC_ALL=C /usr/bin/sort)"
EXPECTED_ROOT_ENTRIES="$(/usr/bin/printf '%s\n' '.DS_Store' '.background' 'Applications' '一爪.app' | LC_ALL=C /usr/bin/sort)"
[[ "$ROOT_ENTRIES" == "$EXPECTED_ROOT_ENTRIES" ]] \
    || fail "fixture DMG contains unexpected root entries: $ROOT_ENTRIES"
[[ "$(/usr/bin/readlink "$MOUNT_DIR/Applications")" == /Applications ]] \
    || fail "Applications link target changed"
/usr/bin/cmp "$BACKGROUND" "$MOUNT_DIR/.background/DMGBackground.png"
PYTHONPATH="$PYTHONPATH_VALUE" "$PYTHON_BIN" "$LAYOUT_SCRIPT" verify "$MOUNT_DIR"
/usr/bin/hdiutil detach -quiet "$MOUNT_DIR"
MOUNTED=false

/usr/bin/printf '%s\n' \
    "PASS headless DMG layout fixture" \
    "Window: 793x496; icons: 一爪.app 215,275 -> Applications 578,275" \
    "Root: .DS_Store, .background, Applications, 一爪.app" \
    > "$TEST_DIR/summary.txt"
/bin/cat "$TEST_DIR/summary.txt"
