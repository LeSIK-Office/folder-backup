#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target BackupCore
bin_path="$(swift build --show-bin-path)"
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library \
  Sources/FolderBackup/BackupStore.swift Tests/RuntimeSelfCheck.swift \
  -I "$bin_path/Modules" "$bin_path"/BackupCore.build/*.swift.o \
  -o .build/runtime-checks
runtime_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/FolderBackup-runtime-restart.XXXXXX")"
.build/runtime-checks --save-process-fixture "$runtime_fixture_dir/plans.json"
.build/runtime-checks --resolve-settings "$runtime_fixture_dir/plans.json"
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library \
  Sources/FolderBackup/AppLifecycle.swift Tests/AppLifecycleCheck.swift -o .build/app-lifecycle-check
.build/app-lifecycle-check
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library \
  Sources/FolderBackup/BackupStore.swift Tests/VerificationRuntimeCheck.swift \
  -I "$bin_path/Modules" "$bin_path"/BackupCore.build/*.swift.o \
  -o .build/verification-runtime-check
.build/verification-runtime-check
