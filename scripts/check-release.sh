#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export MACOSX_DEPLOYMENT_TARGET=14.0
swift run -c release BackupCoreChecks
zsh scripts/check-runtime.sh
bin_dir="$(swift build -c release --arch "$(uname -m)" --show-bin-path)"
for check in LocalizationCheck BackupMemoryCheck FaultRecoveryCheck; do
    swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library \
        "Tests/$check.swift" -I "$bin_dir/Modules" "$bin_dir"/BackupCore.build/*.swift.o \
        -o ".build/$check"
done
.build/LocalizationCheck
.build/BackupMemoryCheck
cp .build/FaultRecoveryCheck .build/fault-recovery-check
python3 scripts/check-faults.py
python3 Tests/PublicExportCheck.py
python3 Tests/BuildManifestCheck.py
