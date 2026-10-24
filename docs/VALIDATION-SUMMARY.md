# Validation summary

This is a local beta candidate, not a notarized public binary release.

Confirmed on October 22, 2026:

- 17 core backup/restore workflows, including shared incremental storage,
  interrupted backup reuse, metadata, corruption detection and retention.
- Scheduling, persisted folder access, settings, background residence and reopen.
- Five language catalogs, primary-language fallback and manual language override.
- Actual external-drive restores of 240 randomly selected and size-stratified
  regular files across three completed versions: 1,195,081,147 bytes and no
  restored SHA-256 mismatch. 192 files also matched the current Mac source byte
  for byte; 45 current sources no longer existed and 3 had changed after backup.
- Test-image fault cases: killed backup, disconnect/remount, full backup and
  restore destinations, corrupted packed content, killed restore and a fresh
  successful restore. Earlier completed versions remained readable.

- Full restoration of the latest real backup: 453,024 regular files,
  49,796,768,925 bytes, 50,679 directories and 769 symbolic links. After cleanly
  unmounting and remounting the restored test image, independent SHA-256 checks
  matched every regular file. Permissions and modification times matched for
  all 503,703 non-link entries. The complete file tree had no missing or extra
  entries, and the restored APFS filesystem passed a read-only filesystem check.
- Full restore took 47.55 minutes; independent hashing took 6.90 minutes.
  380,601 restored files also matched the current source. Another 3,660 sources
  had changed and 68,763 no longer existed; their restored content still matched
  the recorded backup hashes. Existing backup storage and settings were unchanged.
- Backup and restore disk-full failures, missing destination handling and
  malformed catalog paths have regression checks. All three real catalogs pass
  validation. The exported source builds cleanly and the universal app contains
  both arm64 and x86_64 executables with a verified source manifest.

The local test machine used Apple Silicon and macOS 27.0.1. Full restoration
used an APFS sparse image stored on an exFAT external drive; separate fixture
checks exercised packed incremental storage, retention and restore directly on
that exFAT drive. Test data remains separate from the real backup store.

Not yet established: Developer ID distribution/notarization, downloaded install
on another Mac, Intel hardware execution, oldest-supported macOS execution and
physical power-loss behavior. A fixture, universal build or sample restore does
not replace those checks.

## Version 1.6.0 beta 1 — October 24, 2026

The new verification action checks stored regular-file contents and catalog
consistency without producing a restore directory or modifying the backup store.
Version verification results and timestamps live only in local plan settings.

Targeted automated checks cover packed and loose content, one read per shared
object across two versions, renamed aliases, every missing/corrupt path,
continuation past failures, progress/cancellation, writer exclusion, incomplete
version rejection, truncated catalogs, legacy catalogs and old settings.
Runtime checks exercise default OFF, opt-in daily/weekly/monthly intervals,
existing/new versions, persisted results, independent paused-backup settings,
continuous-backup scheduling and cancelled/failed checks.

The complete real-data restore figures above were measured on October 22 with
1.5.1. They have not been repeated as a new full restore of 1.6.0. Tests of this
feature are checksum verification, not a claim of another physical test restore.

### 한국어

1.6.0의 버전 검사는 복원 사본을 만들지 않고 저장된 일반 파일과 목록을 확인합니다.
백업·원본은 읽기만 하며 결과·시각은 Mac 계획 설정에만 기록합니다. 중복 내용·이름 변경·
손상·누락·취소·동시 쓰기·미완료 거부·이전 형식과 예약·설정 유지 검사를 포함합니다.
위의 실제 데이터 전체 복원 수치는 10월 22일 1.5.1에서 측정한 것이며 1.6.0에서 전체
복원을 다시 수행했다는 의미가 아닙니다.
