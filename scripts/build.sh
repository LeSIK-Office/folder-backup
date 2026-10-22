#!/bin/zsh
set -eu
cd "${0:A:h:h}"
build_root="$(mktemp -d /tmp/FolderBackup-build.XXXXXX)"
python3 scripts/build-manifest.py create "$build_root/BuildSourceManifest.json"
for architecture in arm64 x86_64; do
    swift build --scratch-path "$build_root" -c release --arch "$architecture" \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
        -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." --product FolderBackup
done
python3 scripts/build-manifest.py verify "$build_root/BuildSourceManifest.json"
bin_dir="$(swift build --scratch-path "$build_root" -c release --arch arm64 --show-bin-path)"
intel_bin_dir="$(swift build --scratch-path "$build_root" -c release --arch x86_64 --show-bin-path)"
app_dir="$PWD/dist/Folder Backup.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create "$bin_dir/FolderBackup" "$intel_bin_dir/FolderBackup" -output "$app_dir/Contents/MacOS/FolderBackup"
strip -S "$app_dir/Contents/MacOS/FolderBackup"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/FolderBackupMark.png "$app_dir/Contents/Resources/FolderBackupMark.png"
cp Resources/FolderBackup.icns "$app_dir/Contents/Resources/FolderBackup.icns"
cp LICENSE PRIVACY.md "$app_dir/Contents/Resources/"
cp "$build_root/BuildSourceManifest.json" "$app_dir/Contents/Resources/"
cp -R "$bin_dir/FolderBackup_BackupCore.bundle" "$app_dir/Contents/Resources/"
for locale in en ko ja zh-Hans es; do
    mkdir -p "$app_dir/Contents/Resources/$locale.lproj"
    cp "Resources/$locale.lproj/InfoPlist.strings" "$app_dir/Contents/Resources/$locale.lproj/"
done
identity="${CODESIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --identifier local.folderbackup "$app_dir"
else
    codesign --force --sign "$identity" --identifier local.folderbackup --options runtime --timestamp "$app_dir"
fi
codesign --verify --strict "$app_dir"
echo "$app_dir"
