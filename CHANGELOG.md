# Changelog

## 1.6.1 beta 2 — 2026-10-24 (build 18)

- Apple notarization accepted for the existing build 18; staple and validate the ticket.
- Gatekeeper assessment accepts the app as **Notarized Developer ID**.
- Publish the ticket-bearing ZIP and updated checksums. Application code and backup format are unchanged.

### 한국어

- 기존 빌드 18의 Apple 공증 승인을 받고 공증 티켓 첨부·검증을 마쳤습니다.
- Gatekeeper의 **Notarized Developer ID** 판정을 확인했습니다.
- 공증 티켓을 포함한 ZIP과 체크섬을 배포합니다. 앱 코드와 백업 형식은 동일합니다.

## 1.6.1 beta 1 — 2026-10-24 (build 18)

- Keep saved backup cards visible while calculating disk usage. Switching back to the app no longer restarts a full storage scan.
- Cancel superseded disk-usage scans and avoid rescanning after read-only verification.
- Sign the universal app with Developer ID, hardened runtime and a secure timestamp. Apple notarization remains pending.

### 한국어

- 디스크 사용량을 계산하기 전에 백업 목록부터 표시하며, 앱으로 돌아올 때마다 전체 목록을 다시 로딩하지 않습니다.
- 이전 용량 계산 작업은 취소하고, 읽기 전용 검사 완료 후 불필요한 재탐색을 생략합니다.
- Developer ID·강화된 런타임·보안 타임스탬프 서명을 적용했습니다. Apple 공증은 아직 진행하지 않았습니다.

## 1.6.0 beta 1 — 2026-10-24 (build 17)

- Add per-version **Verify Version** with SHA-256 checks, progress, cancellation and detailed missing/corrupt/unreadable paths.
- Add optional per-job daily/weekly/monthly verification, default OFF. Existing and new completed versions use the same due rule.
- Check shared contents once per batch; leave backup/source contents unchanged and create no restore folder. Store results and last verification time only in local plan settings.
- Show failed-version badges and quiet successful results. Preserve completed results on cancellation and keep backup scheduling independent.
- Add five-language verification UI and regression checks for read-only behavior, deduplication, corruption, missing files, legacy versions, scheduling and persistence.
- Test-restore idea credited to @RyanJ_KOL in the supplied feature brief; no endorsement implied.

### 한국어

- 완료본별 **버전 검사**, SHA-256 진행률·취소·누락/손상 파일 상세를 추가했습니다.
- 기본 꺼짐의 매일·매주·매월 예약 검사를 추가했습니다. 기존·새 완료본을 같은 기준으로 확인합니다.
- 공유 내용은 한 번 읽고 백업·원본은 변경하지 않습니다. 결과·검사 시각은 Mac의 계획 설정에만 저장합니다.
- 실패 경고, 조용한 성공 기록, 5개 언어와 읽기 전용·손상·취소·예약·이전 버전 호환 검사를 포함합니다.


## 1.5.1 beta 1

- Folder-based incremental backups with shared file contents and retained versions.
- Scheduled backups, interrupted-backup recovery and version management.
- Restore complete versions or selected files into a new folder.
- System language detection and manual English, Korean, Japanese, Simplified
  Chinese and Spanish selection.
- Independent Folder Backup branding and blue folder/check icon.
- Preserve the menu bar icon when closing the main window and restore Dock
  presence when reopening the app.
- Browse large restore catalogs without repeated disk lookups for virtual paths.
- Stop promptly when storage fills or the destination disappears, preserving
  the actual cause rather than grouping it with individual-file failures.
- Reject malformed catalog paths and symbolic-link targets before filesystem use.
- Universal app packaging for Apple Silicon and Intel; Intel execution has not
  yet been tested on hardware.

This is a local beta candidate. Developer ID signing, Apple notarization and a
clean installation on another Mac remain release gates.
