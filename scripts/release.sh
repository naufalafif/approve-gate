#!/usr/bin/env bash
# Builds the signed APK on this Mac and publishes it as a GitHub release, where Obtainium picks it up.
# The tag is v<versionName>, so Obtainium's version check matches the installed app.
# Usage: scripts/release.sh   (bump versionCode and versionName in android/app/build.gradle.kts first)
set -euo pipefail

cd "$(dirname "$0")/.."

# The release certificate. A different key would make Android refuse the update and lose the pairing.
EXPECTED_CERT="3a66ba332113d7beb1a39e7311c65aace379ff747b167f624e4eb0af51a40826"
KS="${AG_KEYSTORE:?set AG_KEYSTORE to your release keystore, for example in local.mk}"
APKSIGNER="$(find /opt/homebrew/share/android-commandlinetools/build-tools -name apksigner -type f | sort -V | tail -1)"

die() { echo "release: $*" >&2; exit 1; }

version="$(sed -nE 's/^ *versionName = "([^"]+)".*/\1/p' android/app/build.gradle.kts)"
code="$(sed -nE 's/^ *versionCode = ([0-9]+).*/\1/p' android/app/build.gradle.kts)"
[[ -n "$version" && -n "$code" ]] || die "could not read versionName/versionCode"
tag="v$version"

[[ "$(git branch --show-current)" == "main" ]] || die "release from main"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "push main first, so the release matches a commit CI has checked"
if gh release view "$tag" >/dev/null 2>&1; then die "$tag already exists: bump versionName and versionCode"; fi

echo "Building $tag (versionCode $code)"
password="$(security find-generic-password -s approve-gate-keystore -w)"
(cd android && AG_KEYSTORE="$KS" AG_KEYSTORE_PASSWORD="$password" ./gradlew -q --no-daemon assembleRelease)
unset password

apk="android/app/build/outputs/apk/release/app-release.apk"
cert="$("$APKSIGNER" verify --print-certs "$apk" | sed -nE 's/^Signer #1 certificate SHA-256 digest: ([0-9a-f]+)$/\1/p')"
[[ "$cert" == "$EXPECTED_CERT" ]] || die "APK is signed with an unexpected certificate ($cert)"

mkdir -p dist
out="dist/ApproveGate-$version.apk"
cp "$apk" "$out"
sha="$(shasum -a 256 "$out" | cut -d' ' -f1)"

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
cat >"$notes" <<EOF
Approve Gate $version (versionCode $code), built from $(git rev-parse --short HEAD).

- APK SHA-256: \`$sha\`
- Signing certificate SHA-256: \`$cert\`

Install or update with Obtainium, or download the APK and open it on the phone.
EOF

gh release create "$tag" "$out" --title "Approve Gate $version" --notes-file "$notes" --target "$(git rev-parse HEAD)"
echo "Released $tag: $out"
