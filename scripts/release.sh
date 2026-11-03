#!/bin/bash
# Builds the Release app and packages it for a GitHub release: Pomelo-<version>.zip and its SHA-256.
# Usage: scripts/release.sh [--allow-dirty] [--ad-hoc]
# Everything is built under ~/Library/Caches/Pomelo-build (never in the repository, never in /Applications).
#
# Releases are signed with the maintainer's self-signed "Pomelo" code-signing certificate (or the identity in
# $POMELO_SIGNING_IDENTITY). macOS ties a user's folder and Automation permissions to the app's signature: an ad hoc
# signature changes with every build, so each update would ask for every folder again, while one certificate keeps
# them. --ad-hoc builds without it (for anyone else building a zip).
set -euo pipefail

ALLOW_DIRTY=0
AD_HOC=0
for argument in "$@"; do
    case "$argument" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --ad-hoc) AD_HOC=1 ;;
        *) echo "usage: scripts/release.sh [--allow-dirty] [--ad-hoc]" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/Pomelo-build"
DERIVED="$BUILD/xcode-release"
OUT="$BUILD/release"

if [[ $ALLOW_DIRTY -eq 0 && -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "The working tree has uncommitted changes; commit them or pass --allow-dirty." >&2
    exit 1
fi

IDENTITY=""
if [[ $AD_HOC -eq 0 ]]; then
    NAME="${POMELO_SIGNING_IDENTITY:-Pomelo}"
    # Self-signed, so not "valid" for find-identity -v; codesign signs with it all the same.
    IDENTITY="$(security find-identity -p codesigning | awk -v name="\"$NAME\"" '$3 == name { print $2; exit }')"
    if [[ -z "$IDENTITY" ]]; then
        echo "No code-signing identity named \"$NAME\" in the keychain; pass --ad-hoc to build without it." >&2
        exit 1
    fi
fi

command -v xcodegen >/dev/null || { echo "Needs XcodeGen: brew install xcodegen" >&2; exit 1; }
(cd App && xcodegen generate --quiet)

rm -rf "$DERIVED"
xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Release \
    -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO build -quiet

APP="$DERIVED/Build/Products/Release/Pomelo.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "io.github.pomelo-app.Pomelo" ]] || { echo "Unexpected bundle identifier $BUNDLE_ID" >&2; exit 1; }

if [[ -n "$IDENTITY" ]]; then
    # Inside out: the Quick Action extension, then the app. Each keeps the entitlements and flags Xcode gave it.
    while IFS= read -r -d '' nested; do
        codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$nested"
    done < <(find "$APP/Contents" -depth \( -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) -print0)
    codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$APP"
    codesign -dr - "$APP" 2>&1 | grep -q 'certificate root' || { echo "The app is not signed with the certificate" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Pomelo")"

mkdir -p "$OUT"
ZIP="$OUT/Pomelo-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's symlinks and signatures intact, as Finder's Compress does.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "Built $ZIP"
cat "$ZIP.sha256"
