#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app_dir="$PWD/dist/Folder Backup.app"
test -d "$app_dir" || { echo 'Build the app with zsh scripts/build.sh first.'; exit 1; }
codesign --verify --strict "$app_dir"
python3 scripts/build-manifest.py verify "$app_dir/Contents/Resources/BuildSourceManifest.json"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
beta_number="${BETA_NUMBER:-1}"
[[ "$beta_number" == <-> && "$beta_number" -ge 1 ]] || { echo 'BETA_NUMBER must be a positive integer.'; exit 1; }
output="$PWD/dist/release-$(date +%Y%m%d-%H%M%S)"
mkdir "$output"
python3 scripts/export-public.py "$output/FolderBackup-$version-source"
ditto -c -k --sequesterRsrc --keepParent "dist/Folder Backup.app" "$output/FolderBackup-$version-beta.$beta_number-universal.zip"
ditto -c -k --keepParent "$output/FolderBackup-$version-source" "$output/FolderBackup-$version-source.zip"
cp LICENSE PRIVACY.md PRIVACY.ko.md THIRD_PARTY_NOTICES.md CHANGELOG.md docs/LEGAL.md docs/VALIDATION-SUMMARY.md "$output/"
(
    cd "$output"
    shasum -a 256 *.zip > SHA256SUMS
)
echo "Local beta artifacts: $output"
echo 'Not published. Verify the signing identity, notarization ticket and checksums before distribution.'
