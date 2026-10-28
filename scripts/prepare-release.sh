#!/bin/zsh
# Local preparation only. This script never creates a tag, pushes or uploads.
set -eu
cd "$(dirname "$0")/.."
python3 scripts/check-source-boundary.py --tree .
if git rev-parse --show-toplevel >/dev/null 2>&1 && [[ "$(git rev-parse --show-toplevel)" == "$PWD" ]]; then
    python3 scripts/check-source-boundary.py --git-index .
fi
releaseRoot="$PWD"
releaseVersion=$(cat VERSION)
if [[ ! "$releaseVersion" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "VERSION must contain a three-part release version."
    exit 1
fi
if [[ $(uname -m) != arm64 ]]; then
    print -u2 "This release script currently packages Apple Silicon builds only."
    exit 1
fi
releaseNotes="${1:?Usage: zsh scripts/prepare-release.sh release-notes.md [output-directory]}"
if [[ ! -s "$releaseNotes" ]]; then
    print -u2 "Release notes must be a non-empty file."
    exit 1
fi
releaseOutput="${2:-$releaseRoot/dist/releases/v$releaseVersion}"
if [[ -e "$releaseOutput" ]]; then
    print -u2 "Output already exists; use a new directory to avoid replacing prepared releases."
    exit 1
fi
sparkleTools="$releaseRoot/.build/artifacts/sparkle/Sparkle/bin"
swift package resolve
# Only read the public key. Never export the private key or create a replacement key here.
signingPublicKey=$("$sparkleTools/generate_keys" --account fuyuan9972-svg.LightTable.updates -p)
expectedPublicKey=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Configuration/Updates.plist)
if [[ "$signingPublicKey" != "$expectedPublicKey" ]]; then
    print -u2 "The update signing key does not match Configuration/Updates.plist."
    exit 1
fi
releaseApp="$releaseRoot/dist/v$releaseVersion/观片台.app"
zsh scripts/build-app.sh "$releaseApp"
python3 scripts/check-update-bundle.py "$releaseApp"
mkdir -p "$releaseOutput"
releaseOutput="${releaseOutput:A}"
releaseBase="LightTable-v$releaseVersion-macOS-arm64"
ditto -c -k --sequesterRsrc --keepParent "$releaseApp" "$releaseOutput/$releaseBase.zip"
python3 scripts/check-source-boundary.py --archive "$releaseOutput/$releaseBase.zip"
cp "$releaseNotes" "$releaseOutput/$releaseBase.md"
"$sparkleTools/generate_appcast" --account fuyuan9972-svg.LightTable.updates \
    --download-url-prefix "https://github.com/fuyuan9972-svg/LightTable/releases/download/v$releaseVersion/" \
    --link "https://github.com/fuyuan9972-svg/LightTable/releases/tag/v$releaseVersion" \
    --full-release-notes-url "https://github.com/fuyuan9972-svg/LightTable/releases" \
    --maximum-deltas 0 --embed-release-notes "$releaseOutput"
python3 scripts/check-update-bundle.py "$releaseApp" "$releaseOutput/appcast.xml"
(
    cd "$releaseOutput"
    shasum -a 256 "$releaseBase.zip" appcast.xml "$releaseBase.md" > SHA256SUMS.txt
)
print "Prepared locally: $releaseOutput"
print "No Git commits, tags or uploads were made."
