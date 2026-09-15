#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE_NAME="一爪"
ASSET_PREFIX="OnePaw"
EXECUTABLE_NAME="CrossToolApp"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.icns"
DMG_BACKGROUND_SOURCE="$PROJECT_DIR/Resources/Installer/DMGBackground.png"
DMG_LAYOUT_SCRIPT="$PROJECT_DIR/scripts/dmg-layout.py"
DMG_LAYOUT_VENDOR_DIR="$PROJECT_DIR/scripts/vendor"
DMG_DS_STORE_WHEEL="$DMG_LAYOUT_VENDOR_DIR/ds_store-1.3.1-py3-none-any.whl"
DMG_MAC_ALIAS_WHEEL="$DMG_LAYOUT_VENDOR_DIR/mac_alias-2.2.2-py3-none-any.whl"
DMG_DS_STORE_WHEEL_SHA256="fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5"
DMG_MAC_ALIAS_WHEEL_SHA256="504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd"
INSTALLER_SCRIPTS_DIR="$PROJECT_DIR/scripts/installer"
source "$PROJECT_DIR/scripts/verify-app-brand.sh"
TEAM_ID="8LSY655LKD"
DEFAULT_APPLICATION_IDENTITY="Developer ID Application: Suzhou Qidian Storm Information Technology Co., Ltd. ($TEAM_ID)"
DEFAULT_INSTALLER_IDENTITY="Developer ID Installer: Suzhou Qidian Storm Information Technology Co., Ltd. ($TEAM_ID)"

SKIP_NOTARIZATION=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-release.sh [--skip-notarization]

Builds Developer ID signed release artifacts:
  - a ZIP containing the notarized and stapled 一爪.app
  - a notarized and stapled OnePaw-*.dmg for drag-to-Applications install
  - a notarized and stapled 一爪-*.pkg installer (recommended for old-name upgrades)
  - SHA256SUMS.txt

Environment:
  CROSSTOOL_APPLICATION_IDENTITY  Developer ID Application identity name or SHA-1
  CROSSTOOL_INSTALLER_IDENTITY    Developer ID Installer identity name or SHA-1
  CROSSTOOL_NOTARY_PROFILE        notarytool Keychain profile name (required normally)
  CROSSTOOL_ARCHS                 Space-separated architectures (default: arm64 x86_64)

--skip-notarization creates signed local QA artifacts only. Those artifacts are
not suitable for a public GitHub release and are marked with "-unnotarized".
DMG/ZIP do not migrate old application names. Use PKG to upgrade an installed
Crosio.app or crosstool.app with identity checks and recoverable backups.
USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

verify_image_document_registration() {
    local plist_path="$1"
    local label="$2"
    onepaw_verify_bundle_brand "$plist_path" "$label" || die "$label has an invalid product name or compatibility identifier"
    local document_type_count
    local document_type_entry
    local type_name
    local role
    local rank
    local content_type_count
    local content_type
    local has_document_class=false

    document_type_count="$(plutil -extract CFBundleDocumentTypes raw -expect array -o - "$plist_path" 2>/dev/null || true)"
    document_type_entry="$(plutil -extract CFBundleDocumentTypes.0 raw -expect dictionary -o - "$plist_path" 2>/dev/null || true)"
    type_name="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeName raw -expect string -o - "$plist_path" 2>/dev/null || true)"
    role="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw -expect string -o - "$plist_path" 2>/dev/null || true)"
    rank="$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw -expect string -o - "$plist_path" 2>/dev/null || true)"
    content_type_count="$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes raw -expect array -o - "$plist_path" 2>/dev/null || true)"
    content_type="$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw -expect string -o - "$plist_path" 2>/dev/null || true)"
    if plutil -extract CFBundleDocumentTypes.0.NSDocumentClass xml1 -o - "$plist_path" >/dev/null 2>&1; then
        has_document_class=true
    fi

    [[ "$document_type_count" == "1" ]] || die "$label must contain exactly one CFBundleDocumentTypes entry"
    [[ -n "$document_type_entry" ]] || die "$label document type must be a dictionary"
    [[ "$type_name" == "图片" ]] || die "$label must name its single document type 图片"
    [[ "$role" == "Viewer" ]] || die "$label must register images with CFBundleTypeRole=Viewer"
    [[ "$rank" == "Alternate" ]] || die "$label must register images with LSHandlerRank=Alternate"
    [[ "$content_type_count" == "1" ]] || die "$label must contain exactly one image content type"
    [[ "$content_type" == "public.image" ]] || die "$label must register public.image"
    [[ "$has_document_class" == false ]] || die "$label must deliver image URLs through NSApplicationDelegate"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarization)
            SKIP_NOTARIZATION=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

[[ -f "$INFO_PLIST" ]] || die "missing Info.plist: $INFO_PLIST"
[[ -f "$ICON_SOURCE" ]] || die "missing app icon: $ICON_SOURCE"
[[ -f "$DMG_BACKGROUND_SOURCE" && ! -L "$DMG_BACKGROUND_SOURCE" ]] \
    || die "missing or symlinked DMG background: $DMG_BACKGROUND_SOURCE"
[[ -f "$DMG_LAYOUT_SCRIPT" && ! -L "$DMG_LAYOUT_SCRIPT" ]] \
    || die "missing or symlinked DMG layout script: $DMG_LAYOUT_SCRIPT"
[[ -f "$DMG_DS_STORE_WHEEL" && ! -L "$DMG_DS_STORE_WHEEL" ]] \
    || die "missing or symlinked vendored ds_store wheel: $DMG_DS_STORE_WHEEL"
[[ -f "$DMG_MAC_ALIAS_WHEEL" && ! -L "$DMG_MAC_ALIAS_WHEEL" ]] \
    || die "missing or symlinked vendored mac_alias wheel: $DMG_MAC_ALIAS_WHEEL"
[[ "$(shasum -a 256 "$DMG_DS_STORE_WHEEL" | awk '{ print $1 }')" == "$DMG_DS_STORE_WHEEL_SHA256" ]] \
    || die "vendored ds_store wheel checksum changed"
[[ "$(shasum -a 256 "$DMG_MAC_ALIAS_WHEEL" | awk '{ print $1 }')" == "$DMG_MAC_ALIAS_WHEEL_SHA256" ]] \
    || die "vendored mac_alias wheel checksum changed"
[[ -x "$INSTALLER_SCRIPTS_DIR/preinstall" ]] || die "missing executable installer preinstall script"
[[ -x "$INSTALLER_SCRIPTS_DIR/postinstall" ]] || die "missing executable installer postinstall script"
[[ -f "$INSTALLER_SCRIPTS_DIR/migration-common.sh" ]] || die "missing installer migration helper"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
MINIMUM_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST")"
ICON_DECLARATION="$(plutil -extract CFBundleIconFile raw -o - "$INFO_PLIST" 2>/dev/null || true)"
AGENT_APP="$(plutil -extract LSUIElement raw -expect bool -o - "$INFO_PLIST" 2>/dev/null || true)"
BACKGROUND_ONLY="$(plutil -extract LSBackgroundOnly raw -expect bool -o - "$INFO_PLIST" 2>/dev/null || true)"

[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || die "release version must be numeric for safe upgrade comparison: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "CFBundleVersion must be numeric: $BUILD_NUMBER"
[[ "$BUNDLE_ID" == "com.cross.crosstool" ]] || die "unexpected bundle identifier: $BUNDLE_ID"
[[ "$ICON_DECLARATION" == "AppIcon.icns" ]] || die "Info.plist must declare CFBundleIconFile=AppIcon.icns"
[[ "$AGENT_APP" == "true" ]] || die "Info.plist must declare LSUIElement=true as a Boolean"
[[ "$BACKGROUND_ONLY" != "true" ]] || die "Info.plist must not declare LSBackgroundOnly=true"
verify_image_document_registration "$INFO_PLIST" "source Info.plist"

DMG_BACKGROUND_WIDTH="$(sips -g pixelWidth "$DMG_BACKGROUND_SOURCE" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
DMG_BACKGROUND_HEIGHT="$(sips -g pixelHeight "$DMG_BACKGROUND_SOURCE" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
DMG_BACKGROUND_DPI_WIDTH="$(sips -g dpiWidth "$DMG_BACKGROUND_SOURCE" 2>/dev/null | awk '/dpiWidth:/ { print $2 }')"
DMG_BACKGROUND_DPI_HEIGHT="$(sips -g dpiHeight "$DMG_BACKGROUND_SOURCE" 2>/dev/null | awk '/dpiHeight:/ { print $2 }')"
[[ "$DMG_BACKGROUND_WIDTH" == "1586" && "$DMG_BACKGROUND_HEIGHT" == "992" ]] \
    || die "DMG background must be the approved 1586x992 Retina artwork"
[[ "$DMG_BACKGROUND_DPI_WIDTH" == "144.000" && "$DMG_BACKGROUND_DPI_HEIGHT" == "144.000" ]] \
    || die "DMG background must use 144 dpi so Finder displays it at 793x496 points"
DMG_LAYOUT_PYTHON="$(xcrun --find python3 2>/dev/null || true)"
[[ -x "$DMG_LAYOUT_PYTHON" ]] || die "Xcode Python is required to create the Finder DMG layout"
DMG_LAYOUT_PYTHONPATH="$DMG_DS_STORE_WHEEL:$DMG_MAC_ALIAS_WHEEL"
PACKAGE_VERSION="$VERSION.$BUILD_NUMBER"

APPLICATION_IDENTITY="${CROSSTOOL_APPLICATION_IDENTITY:-$DEFAULT_APPLICATION_IDENTITY}"
INSTALLER_IDENTITY="${CROSSTOOL_INSTALLER_IDENTITY:-$DEFAULT_INSTALLER_IDENTITY}"
NOTARY_PROFILE="${CROSSTOOL_NOTARY_PROFILE:-}"

if [[ "$SKIP_NOTARIZATION" == false && -z "$NOTARY_PROFILE" ]]; then
    die "CROSSTOOL_NOTARY_PROFILE is required. Store credentials once with 'xcrun notarytool store-credentials <profile>', then export only the profile name."
fi

CODESIGN_IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
BASIC_IDENTITIES="$(security find-identity -v -p basic 2>&1)"
grep -Fq "$APPLICATION_IDENTITY" <<< "$CODESIGN_IDENTITIES" || die "Developer ID Application identity not found: $APPLICATION_IDENTITY"
grep -Fq "$INSTALLER_IDENTITY" <<< "$BASIC_IDENTITIES" || die "Developer ID Installer identity not found: $INSTALLER_IDENTITY"

ARCHS_VALUE="${CROSSTOOL_ARCHS:-arm64 x86_64}"
read -r -a ARCHS <<< "$ARCHS_VALUE"
[[ ${#ARCHS[@]} -gt 0 ]] || die "CROSSTOOL_ARCHS cannot be empty"

SWIFT_ARCH_ARGS=()
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64)
            SWIFT_ARCH_ARGS+=(--arch "$arch")
            ;;
        *)
            die "unsupported architecture: $arch"
            ;;
    esac
done

mkdir -p "$PROJECT_DIR/.build"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/crosstool-release.XXXXXX")"
DMG_MOUNT_DIR=""
DMG_MOUNTED=false
cleanup() {
    local can_remove_staging=true

    if [[ "$DMG_MOUNTED" == true && -n "$DMG_MOUNT_DIR" ]]; then
        if hdiutil detach -quiet "$DMG_MOUNT_DIR" >/dev/null 2>&1; then
            DMG_MOUNTED=false
        elif hdiutil detach -force -quiet "$DMG_MOUNT_DIR" >/dev/null 2>&1; then
            DMG_MOUNTED=false
        else
            can_remove_staging=false
            echo "WARNING: could not detach the DMG verification mount; preserving staging at $STAGING_DIR" >&2
        fi
    fi

    if [[ "$can_remove_staging" == true ]]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

APP_BUNDLE="$STAGING_DIR/$APP_BUNDLE_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building 一爪 $VERSION ($BUILD_NUMBER) for ${ARCHS[*]}..."
swift build --package-path "$PROJECT_DIR" -c release "${SWIFT_ARCH_ARGS[@]}"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release "${SWIFT_ARCH_ARGS[@]}" --show-bin-path)"
RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -type d -name '*CrossToolApp.bundle' -print -quit)"

[[ -x "$BIN_DIR/$EXECUTABLE_NAME" ]] || die "missing release executable: $BIN_DIR/$EXECUTABLE_NAME"
[[ -n "$RESOURCE_BUNDLE" && -d "$RESOURCE_BUNDLE" ]] || die "missing CrossToolApp resource bundle in $BIN_DIR"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
ditto "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
ditto "$RESOURCE_BUNDLE" "$RESOURCES_DIR/$(basename "$RESOURCE_BUNDLE")"
ditto "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
ditto "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
[[ -f "$RESOURCES_DIR/AppIcon.icns" ]] || die "app bundle is missing Contents/Resources/AppIcon.icns"
cmp -s "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns" || die "app bundle icon differs from source icon"
BUILT_ICON_DECLARATION="$(plutil -extract CFBundleIconFile raw -o - "$CONTENTS_DIR/Info.plist" 2>/dev/null || true)"
[[ "$BUILT_ICON_DECLARATION" == "AppIcon.icns" ]] || die "built app Info.plist has an unexpected CFBundleIconFile"
BUILT_AGENT_APP="$(plutil -extract LSUIElement raw -expect bool -o - "$CONTENTS_DIR/Info.plist" 2>/dev/null || true)"
[[ "$BUILT_AGENT_APP" == "true" ]] || die "built app Info.plist does not declare LSUIElement=true"
verify_image_document_registration "$CONTENTS_DIR/Info.plist" "built app Info.plist"
for arch in "${ARCHS[@]}"; do
    lipo "$MACOS_DIR/$EXECUTABLE_NAME" -verify_arch "$arch"
done

echo "Signing app with hardened runtime and trusted timestamp..."
codesign --force --timestamp --options runtime --sign "$APPLICATION_IDENTITY" "$MACOS_DIR/$EXECUTABLE_NAME"
codesign --force --timestamp --options runtime --sign "$APPLICATION_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

APP_SIGNATURE="$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$APP_SIGNATURE" || die "app is not signed with Developer ID Application"
grep -Fq "TeamIdentifier=$TEAM_ID" <<< "$APP_SIGNATURE" || die "unexpected signing team"
grep -Eq 'flags=.*runtime' <<< "$APP_SIGNATURE" || die "hardened runtime is missing"

BUILT_ARCHS="$(lipo -archs "$MACOS_DIR/$EXECUTABLE_NAME")"
if [[ "$BUILT_ARCHS" == *arm64* && "$BUILT_ARCHS" == *x86_64* ]]; then
    ARCH_LABEL="universal2"
elif [[ "$BUILT_ARCHS" == "arm64" || "$BUILT_ARCHS" == "x86_64" ]]; then
    ARCH_LABEL="$BUILT_ARCHS"
else
    die "unexpected built architectures: $BUILT_ARCHS"
fi

SUFFIX=""
if [[ "$SKIP_NOTARIZATION" == true ]]; then
    SUFFIX="-unnotarized"
fi

RELEASE_DIR="$PROJECT_DIR/dist/release/v$VERSION"
ZIP_PATH="$RELEASE_DIR/$ASSET_PREFIX-$VERSION-macos-$ARCH_LABEL$SUFFIX.zip"
DMG_PATH="$RELEASE_DIR/$ASSET_PREFIX-$VERSION-macos-$ARCH_LABEL$SUFFIX.dmg"
PKG_PATH="$RELEASE_DIR/$ASSET_PREFIX-$VERSION-macos-$ARCH_LABEL$SUFFIX.pkg"
CHECKSUM_PATH="$RELEASE_DIR/SHA256SUMS$SUFFIX.txt"
UNSIGNED_PKG="$STAGING_DIR/$APP_BUNDLE_NAME-unsigned.pkg"
NOTARY_ZIP="$STAGING_DIR/$APP_BUNDLE_NAME-notary-upload.zip"
DMG_ROOT="$STAGING_DIR/dmg-root"
DMG_RW_PATH="$STAGING_DIR/$ASSET_PREFIX-$VERSION-layout.dmg"
DMG_VOLUME_NAME="一爪"
DMG_MOUNT_DIR="$STAGING_DIR/dmg-mount"
PKG_ROOT="$STAGING_DIR/pkg-root"
COMPONENT_PLIST="$STAGING_DIR/components.plist"
EXPANDED_PKG="$STAGING_DIR/expanded-pkg"
EXPANDED_FULL_PKG="$STAGING_DIR/expanded-full-pkg"
FINAL_EXPANDED_FULL_PKG="$STAGING_DIR/final-expanded-full-pkg"
ZIP_VERIFY_DIR="$STAGING_DIR/zip-verify"
STAGED_INSTALLER_SCRIPTS="$STAGING_DIR/installer-scripts"

mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH" "$PKG_PATH" "$CHECKSUM_PATH"

if [[ "$SKIP_NOTARIZATION" == false ]]; then
    echo "Submitting app to Apple notary service..."
    ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    xcrun stapler staple -q "$APP_BUNDLE"
    xcrun stapler validate -q "$APP_BUNDLE"
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
fi

echo "Creating ZIP archive..."
ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ZIP_PATH"

mkdir -p "$ZIP_VERIFY_DIR"
ditto -x -k "$ZIP_PATH" "$ZIP_VERIFY_DIR"
ZIP_APP="$ZIP_VERIFY_DIR/$APP_BUNDLE_NAME.app"
[[ -f "$ZIP_APP/Contents/Resources/AppIcon.icns" ]] || die "ZIP payload is missing AppIcon.icns"
cmp -s "$ICON_SOURCE" "$ZIP_APP/Contents/Resources/AppIcon.icns" || die "ZIP payload icon differs from source icon"
ZIP_ICON_DECLARATION="$(plutil -extract CFBundleIconFile raw -o - "$ZIP_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$ZIP_ICON_DECLARATION" == "AppIcon.icns" ]] || die "ZIP payload Info.plist has an unexpected CFBundleIconFile"
ZIP_AGENT_APP="$(plutil -extract LSUIElement raw -expect bool -o - "$ZIP_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$ZIP_AGENT_APP" == "true" ]] || die "ZIP payload Info.plist does not declare LSUIElement=true"
verify_image_document_registration "$ZIP_APP/Contents/Info.plist" "ZIP payload Info.plist"

echo "Creating drag-to-Applications DMG..."
mkdir -p "$DMG_ROOT" "$DMG_MOUNT_DIR"
ditto "$APP_BUNDLE" "$DMG_ROOT/$APP_BUNDLE_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
/bin/mkdir -p "$DMG_ROOT/.background"
/bin/cp -X "$DMG_BACKGROUND_SOURCE" "$DMG_ROOT/.background/DMGBackground.png"
hdiutil create \
    -quiet \
    -volname "$DMG_VOLUME_NAME" \
    -fs HFS+ \
    -nospotlight \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDRW \
    "$DMG_RW_PATH"

DMG_MOUNTED=true
hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse \
    -mountpoint "$DMG_MOUNT_DIR" \
    "$DMG_RW_PATH" >/dev/null

DMG_LAYOUT_VOLUME_NAME="$(diskutil info -plist "$DMG_MOUNT_DIR" | plutil -extract VolumeName raw -o - -)"
DMG_LAYOUT_WRITABLE="$(diskutil info -plist "$DMG_MOUNT_DIR" | plutil -extract WritableVolume raw -o - -)"
[[ "$DMG_LAYOUT_VOLUME_NAME" == "$DMG_VOLUME_NAME" ]] \
    || die "unexpected writable DMG volume name: $DMG_LAYOUT_VOLUME_NAME"
[[ "$DMG_LAYOUT_WRITABLE" == "true" ]] || die "DMG layout volume is not writable"

PYTHONPATH="$DMG_LAYOUT_PYTHONPATH" \
    "$DMG_LAYOUT_PYTHON" "$DMG_LAYOUT_SCRIPT" write "$DMG_MOUNT_DIR"
PYTHONPATH="$DMG_LAYOUT_PYTHONPATH" \
    "$DMG_LAYOUT_PYTHON" "$DMG_LAYOUT_SCRIPT" verify "$DMG_MOUNT_DIR"

# Keep the disk image free of transient per-volume metadata created while the
# layout volume is writable.
/bin/rm -rf -- \
    "$DMG_MOUNT_DIR/.DocumentRevisions-V100" \
    "$DMG_MOUNT_DIR/.Spotlight-V100" \
    "$DMG_MOUNT_DIR/.Trashes" \
    "$DMG_MOUNT_DIR/.fseventsd"
/usr/bin/find "$DMG_MOUNT_DIR" -mindepth 1 -maxdepth 1 -type f -name '._*' -delete
sync
hdiutil detach -quiet "$DMG_MOUNT_DIR"
DMG_MOUNTED=false

hdiutil convert \
    -quiet \
    "$DMG_RW_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH"
hdiutil verify "$DMG_PATH"
DMG_FORMAT="$(hdiutil imageinfo -format "$DMG_PATH")"
[[ "$DMG_FORMAT" == "UDZO" ]] || die "unexpected DMG image format: $DMG_FORMAT"

DMG_MOUNTED=true
hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$DMG_MOUNT_DIR" \
    "$DMG_PATH" >/dev/null

DMG_VOLUME_NAME_ACTUAL="$(diskutil info -plist "$DMG_MOUNT_DIR" | plutil -extract VolumeName raw -o - -)"
[[ "$DMG_VOLUME_NAME_ACTUAL" == "$DMG_VOLUME_NAME" ]] \
    || die "unexpected DMG volume name: $DMG_VOLUME_NAME_ACTUAL"

DMG_APP="$DMG_MOUNT_DIR/$APP_BUNDLE_NAME.app"
DMG_APPLICATIONS_LINK="$DMG_MOUNT_DIR/Applications"
DMG_ROOT_ENTRIES="$(find "$DMG_MOUNT_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
EXPECTED_DMG_ROOT_ENTRIES="$(printf '%s\n' '.DS_Store' '.background' 'Applications' "$APP_BUNDLE_NAME.app" | LC_ALL=C sort)"
[[ "$DMG_ROOT_ENTRIES" == "$EXPECTED_DMG_ROOT_ENTRIES" ]] \
    || die "DMG root contains unexpected entries: $DMG_ROOT_ENTRIES"
[[ -d "$DMG_APP" && ! -L "$DMG_APP" ]] || die "DMG root is missing $APP_BUNDLE_NAME.app"
[[ -L "$DMG_APPLICATIONS_LINK" ]] || die "DMG root is missing the Applications symlink"
[[ "$(readlink "$DMG_APPLICATIONS_LINK")" == "/Applications" ]] \
    || die "DMG Applications symlink does not target /Applications"
[[ -s "$DMG_MOUNT_DIR/.DS_Store" ]] || die "DMG root is missing its saved Finder layout"
[[ -f "$DMG_MOUNT_DIR/.background/DMGBackground.png" ]] \
    || die "DMG root is missing the installer background"
DMG_BACKGROUND_ENTRY_COUNT="$(find "$DMG_MOUNT_DIR/.background" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
[[ "$DMG_BACKGROUND_ENTRY_COUNT" == "1" ]] \
    || die "DMG .background must contain only DMGBackground.png"
cmp -s "$DMG_BACKGROUND_SOURCE" "$DMG_MOUNT_DIR/.background/DMGBackground.png" \
    || die "DMG installer background differs from the approved artwork"
PYTHONPATH="$DMG_LAYOUT_PYTHONPATH" \
    "$DMG_LAYOUT_PYTHON" "$DMG_LAYOUT_SCRIPT" verify "$DMG_MOUNT_DIR"

DMG_INFO_PLIST="$DMG_APP/Contents/Info.plist"
[[ -f "$DMG_INFO_PLIST" ]] || die "DMG app is missing Contents/Info.plist"
DMG_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$DMG_INFO_PLIST")"
DMG_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$DMG_INFO_PLIST")"
DMG_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$DMG_INFO_PLIST")"
DMG_ICON_DECLARATION="$(plutil -extract CFBundleIconFile raw -o - "$DMG_INFO_PLIST" 2>/dev/null || true)"
DMG_AGENT_APP="$(plutil -extract LSUIElement raw -expect bool -o - "$DMG_INFO_PLIST" 2>/dev/null || true)"
[[ "$DMG_VERSION" == "$VERSION" ]] || die "DMG app has unexpected version: $DMG_VERSION"
[[ "$DMG_BUILD_NUMBER" == "$BUILD_NUMBER" ]] || die "DMG app has unexpected build number: $DMG_BUILD_NUMBER"
[[ "$DMG_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "DMG app has unexpected bundle identifier: $DMG_BUNDLE_ID"
[[ "$DMG_ICON_DECLARATION" == "AppIcon.icns" ]] \
    || die "DMG app Info.plist has an unexpected CFBundleIconFile"
[[ "$DMG_AGENT_APP" == "true" ]] || die "DMG app Info.plist does not declare LSUIElement=true"
verify_image_document_registration "$DMG_INFO_PLIST" "DMG app Info.plist"
[[ -f "$DMG_APP/Contents/Resources/AppIcon.icns" ]] || die "DMG app is missing AppIcon.icns"
cmp -s "$ICON_SOURCE" "$DMG_APP/Contents/Resources/AppIcon.icns" \
    || die "DMG app icon differs from source icon"

DMG_EXECUTABLE="$DMG_APP/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$DMG_EXECUTABLE" ]] || die "DMG app is missing its executable"
for arch in "${ARCHS[@]}"; do
    lipo "$DMG_EXECUTABLE" -verify_arch "$arch"
done
codesign --verify --deep --strict --verbose=2 "$DMG_APP"
DMG_APP_SIGNATURE="$(codesign --display --verbose=4 "$DMG_APP" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$DMG_APP_SIGNATURE" \
    || die "DMG app is not signed with Developer ID Application"
grep -Fq "TeamIdentifier=$TEAM_ID" <<< "$DMG_APP_SIGNATURE" \
    || die "DMG app has an unexpected signing team"
grep -Eq 'flags=.*runtime' <<< "$DMG_APP_SIGNATURE" \
    || die "DMG app is missing the hardened runtime"

hdiutil detach -quiet "$DMG_MOUNT_DIR"
DMG_MOUNTED=false

echo "Signing DMG with Developer ID Application..."
codesign \
    --force \
    --timestamp \
    --sign "$APPLICATION_IDENTITY" \
    --identifier "$BUNDLE_ID.dmg" \
    "$DMG_PATH"
codesign --verify --strict --verbose=4 "$DMG_PATH"
DMG_SIGNATURE="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$DMG_SIGNATURE" \
    || die "DMG is not signed with Developer ID Application"
grep -Fq "TeamIdentifier=$TEAM_ID" <<< "$DMG_SIGNATURE" \
    || die "DMG has an unexpected signing team"
grep -Fq "Identifier=$BUNDLE_ID.dmg" <<< "$DMG_SIGNATURE" \
    || die "DMG has an unexpected signing identifier"
hdiutil verify "$DMG_PATH"

DMG_GATEKEEPER_ASSESSED=false
if [[ "$SKIP_NOTARIZATION" == false ]]; then
    echo "Submitting DMG to Apple notary service..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    xcrun stapler staple -q "$DMG_PATH"
    xcrun stapler validate -q "$DMG_PATH"
    hdiutil verify "$DMG_PATH"
    STAPLED_DMG_FORMAT="$(hdiutil imageinfo -format "$DMG_PATH")"
    [[ "$STAPLED_DMG_FORMAT" == "UDZO" ]] \
        || die "stapled DMG has an unexpected image format: $STAPLED_DMG_FORMAT"
    codesign --verify --strict --verbose=4 "$DMG_PATH"

    DMG_MOUNTED=true
    hdiutil attach \
        -readonly \
        -nobrowse \
        -noautoopen \
        -mountpoint "$DMG_MOUNT_DIR" \
        "$DMG_PATH" >/dev/null
    STAPLED_DMG_ROOT_ENTRIES="$(find "$DMG_MOUNT_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
    [[ "$STAPLED_DMG_ROOT_ENTRIES" == "$EXPECTED_DMG_ROOT_ENTRIES" ]] \
        || die "stapled DMG root contains unexpected entries: $STAPLED_DMG_ROOT_ENTRIES"
    [[ -d "$DMG_MOUNT_DIR/$APP_BUNDLE_NAME.app" && ! -L "$DMG_MOUNT_DIR/$APP_BUNDLE_NAME.app" ]] \
        || die "stapled DMG root is missing $APP_BUNDLE_NAME.app"
    [[ -L "$DMG_MOUNT_DIR/Applications" ]] \
        || die "stapled DMG root is missing the Applications symlink"
    [[ "$(readlink "$DMG_MOUNT_DIR/Applications")" == "/Applications" ]] \
        || die "stapled DMG Applications symlink does not target /Applications"
    [[ -s "$DMG_MOUNT_DIR/.DS_Store" ]] \
        || die "stapled DMG root is missing its saved Finder layout"
    cmp -s "$DMG_BACKGROUND_SOURCE" "$DMG_MOUNT_DIR/.background/DMGBackground.png" \
        || die "stapled DMG installer background differs from the approved artwork"
    PYTHONPATH="$DMG_LAYOUT_PYTHONPATH" \
        "$DMG_LAYOUT_PYTHON" "$DMG_LAYOUT_SCRIPT" verify "$DMG_MOUNT_DIR"
    STAPLED_DMG_INFO_PLIST="$DMG_MOUNT_DIR/$APP_BUNDLE_NAME.app/Contents/Info.plist"
    [[ -f "$STAPLED_DMG_INFO_PLIST" ]] || die "stapled DMG app is missing Contents/Info.plist"
    verify_image_document_registration "$STAPLED_DMG_INFO_PLIST" "stapled DMG app Info.plist"
    hdiutil detach -quiet "$DMG_MOUNT_DIR"
    DMG_MOUNTED=false

    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG_PATH"
    DMG_GATEKEEPER_ASSESSED=true
fi

echo "Creating and signing PKG installer..."
mkdir -p "$PKG_ROOT"
mkdir -p "$STAGED_INSTALLER_SCRIPTS"
/bin/cp -X "$INSTALLER_SCRIPTS_DIR/preinstall" "$STAGED_INSTALLER_SCRIPTS/preinstall"
/bin/cp -X "$INSTALLER_SCRIPTS_DIR/postinstall" "$STAGED_INSTALLER_SCRIPTS/postinstall"
/bin/cp -X "$INSTALLER_SCRIPTS_DIR/migration-common.sh" "$STAGED_INSTALLER_SCRIPTS/migration-common.sh"
/bin/cp -X "$CONTENTS_DIR/Info.plist" "$STAGED_INSTALLER_SCRIPTS/expected-app.plist"
chmod 755 "$STAGED_INSTALLER_SCRIPTS/preinstall" "$STAGED_INSTALLER_SCRIPTS/postinstall"
chmod 644 "$STAGED_INSTALLER_SCRIPTS/migration-common.sh" "$STAGED_INSTALLER_SCRIPTS/expected-app.plist"
ditto "$APP_BUNDLE" "$PKG_ROOT/$APP_BUNDLE_NAME.app"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST"

ROOT_RELATIVE_BUNDLE_PATH="$(plutil -extract 0.RootRelativeBundlePath raw -o - "$COMPONENT_PLIST")"
[[ "$ROOT_RELATIVE_BUNDLE_PATH" == "$APP_BUNDLE_NAME.app" ]] \
    || die "unexpected PKG bundle path: $ROOT_RELATIVE_BUNDLE_PATH"
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
plutil -replace 0.BundleIsVersionChecked -bool YES "$COMPONENT_PLIST"
plutil -replace 0.BundleHasStrictIdentifier -bool YES "$COMPONENT_PLIST"
plutil -replace 0.BundleOverwriteAction -string upgrade "$COMPONENT_PLIST"

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$STAGED_INSTALLER_SCRIPTS" \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$PACKAGE_VERSION" \
    --install-location /Applications \
    --min-os-version "$MINIMUM_MACOS" \
    "$UNSIGNED_PKG"
productsign --timestamp --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$PKG_PATH"

PKG_SIGNATURE="$(pkgutil --check-signature "$PKG_PATH" 2>&1)"
echo "$PKG_SIGNATURE"
grep -Fq "Developer ID Installer:" <<< "$PKG_SIGNATURE" || die "PKG is not signed with Developer ID Installer"
grep -Fq "($TEAM_ID)" <<< "$PKG_SIGNATURE" || die "PKG has an unexpected signing team"

pkgutil --expand "$PKG_PATH" "$EXPANDED_PKG"
PACKAGE_INFO="$EXPANDED_PKG/PackageInfo"
[[ -f "$PACKAGE_INFO" ]] || die "signed PKG has no PackageInfo"
grep -Fq 'install-location="/Applications"' "$PACKAGE_INFO" || die "PKG install location is not /Applications"
grep -Fq 'relocatable="false"' "$PACKAGE_INFO" || die "PKG app bundle is still relocatable"
grep -Fq 'preinstall' "$PACKAGE_INFO" || die "PKG is missing the legacy-app preinstall check"
grep -Fq 'postinstall' "$PACKAGE_INFO" || die "PKG is missing the legacy-app migration script"
[[ -f "$EXPANDED_PKG/Scripts/preinstall" ]] || die "PKG has no expanded preinstall script"
[[ -f "$EXPANDED_PKG/Scripts/postinstall" ]] || die "PKG has no expanded postinstall script"
cmp -s "$INSTALLER_SCRIPTS_DIR/preinstall" "$EXPANDED_PKG/Scripts/preinstall" \
    || die "PKG preinstall script differs from its reviewed source"
cmp -s "$INSTALLER_SCRIPTS_DIR/postinstall" "$EXPANDED_PKG/Scripts/postinstall" \
    || die "PKG postinstall script differs from its reviewed source"
cmp -s "$INSTALLER_SCRIPTS_DIR/migration-common.sh" "$EXPANDED_PKG/Scripts/migration-common.sh" \
    || die "PKG migration helper differs from its reviewed source"
cmp -s "$CONTENTS_DIR/Info.plist" "$EXPANDED_PKG/Scripts/expected-app.plist" \
    || die "PKG expected app metadata differs from its payload"
pkgutil --payload-files "$PKG_PATH" \
    | grep -Eq "^(\\./)?${APP_BUNDLE_NAME}[.]app/Contents/MacOS/${EXECUTABLE_NAME}$" \
    || die "PKG payload does not contain 一爪.app at its fixed root"
pkgutil --payload-files "$PKG_PATH" \
    | grep -Eq "^(\\./)?${APP_BUNDLE_NAME}[.]app/Contents/Resources/AppIcon[.]icns$" \
    || die "PKG payload does not contain AppIcon.icns"
pkgutil --payload-files "$PKG_PATH" \
    | grep -Eq "^(\\./)?${APP_BUNDLE_NAME}[.]app/Contents/Info[.]plist$" \
    || die "PKG payload does not contain the app Info.plist"

pkgutil --expand-full "$PKG_PATH" "$EXPANDED_FULL_PKG"
PKG_EXPANDED_INFO="$(find "$EXPANDED_FULL_PKG" -type f -path "*/$APP_BUNDLE_NAME.app/Contents/Info.plist" -print -quit)"
[[ -n "$PKG_EXPANDED_INFO" ]] || die "expanded PKG payload has no 一爪.app Info.plist"
PKG_EXPANDED_APP="${PKG_EXPANDED_INFO%/Contents/Info.plist}"
[[ -f "$PKG_EXPANDED_APP/Contents/Resources/AppIcon.icns" ]] || die "expanded PKG payload is missing AppIcon.icns"
cmp -s "$ICON_SOURCE" "$PKG_EXPANDED_APP/Contents/Resources/AppIcon.icns" || die "PKG payload icon differs from source icon"
PKG_ICON_DECLARATION="$(plutil -extract CFBundleIconFile raw -o - "$PKG_EXPANDED_INFO" 2>/dev/null || true)"
[[ "$PKG_ICON_DECLARATION" == "AppIcon.icns" ]] || die "PKG payload Info.plist has an unexpected CFBundleIconFile"
PKG_AGENT_APP="$(plutil -extract LSUIElement raw -expect bool -o - "$PKG_EXPANDED_INFO" 2>/dev/null || true)"
[[ "$PKG_AGENT_APP" == "true" ]] || die "PKG payload Info.plist does not declare LSUIElement=true"
verify_image_document_registration "$PKG_EXPANDED_INFO" "PKG payload Info.plist"

if [[ "$SKIP_NOTARIZATION" == false ]]; then
    echo "Submitting PKG to Apple notary service..."
    xcrun notarytool submit "$PKG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    xcrun stapler staple -q "$PKG_PATH"
    xcrun stapler validate -q "$PKG_PATH"
    spctl --assess --type install --verbose=4 "$PKG_PATH"

    pkgutil --expand-full "$PKG_PATH" "$FINAL_EXPANDED_FULL_PKG"
    FINAL_PKG_INFO="$(find "$FINAL_EXPANDED_FULL_PKG" -type f -path "*/$APP_BUNDLE_NAME.app/Contents/Info.plist" -print -quit)"
    [[ -n "$FINAL_PKG_INFO" ]] || die "stapled PKG payload has no 一爪.app Info.plist"
    verify_image_document_registration "$FINAL_PKG_INFO" "stapled PKG payload Info.plist"
    cmp -s "$ICON_SOURCE" "${FINAL_PKG_INFO%/Contents/Info.plist}/Contents/Resources/AppIcon.icns" \
        || die "stapled PKG payload icon differs from source icon"
fi

(
    cd "$RELEASE_DIR"
    shasum -a 256 \
        "$(basename "$ZIP_PATH")" \
        "$(basename "$DMG_PATH")" \
        "$(basename "$PKG_PATH")" \
        > "$(basename "$CHECKSUM_PATH")"
)

echo
echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $PKG_PATH"
echo "  $CHECKSUM_PATH"
echo "Version: $VERSION ($BUILD_NUMBER)"
echo "Architectures: $BUILT_ARCHS"
if [[ "$SKIP_NOTARIZATION" == true ]]; then
    echo "WARNING: local QA build only; notarization, stapling and Gatekeeper assessment were skipped."
else
    echo "Notarization: app, DMG and PKG accepted and stapled"
    [[ "$DMG_GATEKEEPER_ASSESSED" == true ]] || die "DMG Gatekeeper assessment did not complete"
    echo "DMG Gatekeeper assessment: accepted"
fi
