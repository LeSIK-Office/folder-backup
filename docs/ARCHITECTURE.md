# Architecture / 앱 구성

[English README](../README.md) · [한국어 안내](../README.ko.md)

## English

### Components

| Path | Responsibility |
|---|---|
| `Sources/FolderBackup/` | SwiftUI windows, plan editor, settings, saved backups, restore/history browser and AppKit menu bar lifecycle |
| `Sources/FolderBackup/BackupStore.swift` | Persisted plans, folder bookmarks, schedule calculation, background operations and run history |
| `Sources/BackupCore/BackupEngine.swift` | Scan, content hashing, immutable shared objects, checkpoints, catalog validation, restore and retention |
| `Sources/BackupCore/PackedObjects.swift` | System SQLite storage for small content objects on exFAT |
| `Sources/BackupCore/Localization.swift` and `Resources/` | Language selection, five translation catalogs, permission descriptions and app icon |
| `Tests/` | Core workflows plus runtime, localization, storage and fault-injection helpers |
| `scripts/` | Universal build, runtime/preflight checks, icon drawing, source manifest, allowlisted export and release ZIPs |

No third-party Swift packages are fetched. UI and core use Apple frameworks,
Darwin filesystem APIs and the system SQLite library. See [notices](../THIRD_PARTY_NOTICES.md).

### Backup lifecycle

1. Resolve selected folders and destination; reject overlapping paths and a
   different reconnected volume. Acquire a per-plan lock to prevent concurrent writers.
2. Scan entries and inspect previous completed/incomplete records. Unchanged files
   can reuse content through metadata/device/inode signatures; a subsequent run
   is not a full byte-by-byte rehash of every unchanged source.
3. Hash new/changed contents with SHA-256. Use the checksum as a content key;
   equal contents within a plan share storage. Store whole files, not block deltas.
4. Write resumable checkpoint records and retry files changed during copy. Runtime
   sockets/pipes and vanished entries are handled separately from persistent failures.
   Disk-full/disconnected storage stops the run; copied data remains for reuse.
5. Publish a completed catalog only after success. Apply the selected retention
   policy afterwards, preserving objects required by remaining versions.

### On-disk layout

```text
<chosen destination>/Toolkit Backups/<plan UUID>/
  .objects/               shared loose file contents
  .objects.sqlite         packed contents when enabled
  .partial-*/             interrupted backup/checkpoint work
  <dated snapshot>/
    snapshot.json         version summary
    manifest.json         full entry catalog and content references
    sources.json          source-location mapping
    checkpoint.jsonl      recorded copy/checkpoint information
    Work/                 staging area
```

Names such as `Toolkit Backups` and local settings at
`~/Library/Application Support/FolderToolkit/plans.json` are retained from this
project's early name for continuity. They do **not** mean compatibility with the
vendor's Toolkit format. Never copy only a date directory or edit/remove shared
objects manually. Keep the complete plan store together.

### Restore lifecycle

The selected catalog is validated before use, including path traversal, duplicate
paths, invalid content keys and malformed link targets. The engine resolves loose
or packed contents, creates a fresh partial output, checks file hashes, restores
metadata and marks the new output complete only after success. It does not need
to replay earlier versions. Earlier content is nevertheless shared, so all
referenced objects must be present. Original-location restoration creates separate
folders beside the source. There is no in-place source overwrite mode.

SHA-256 detects mismatches against recorded hashes; it is not encryption or a
cryptographic signature proving who wrote the catalog. The store is not designed
as a tamper-proof archive. The scan is not an atomic volume snapshot, so applications
with live databases should be closed or use their own consistent export first.

## 한국어

### 구성 요소

| 경로 | 역할 |
|---|---|
| `Sources/FolderBackup/` | 기본 창, 계획 편집, 설정, 카트리지, 복원·이력, 메뉴 막대 수명주기 |
| `BackupStore.swift` | 계획·북마크·예약 계산·백그라운드 작업·실행 기록 |
| `Sources/BackupCore/BackupEngine.swift` | 탐색·해시·공유 저장·이어받기·목록 검증·복원·보관 정리 |
| `PackedObjects.swift` | exFAT의 작은 파일을 시스템 SQLite에 묶어 저장 |
| `Localization.swift`·리소스 | 5개 언어·언어 선택·접근 권한 설명·아이콘 |
| `Tests/` | 핵심 동작·예약·언어·저장·장애 검사 |
| `scripts/` | Universal 빌드·사전 검사·아이콘 생성·소스 목록·공개 내보내기·ZIP 포장 |

외부 Swift 패키지를 가져오지 않습니다. Apple 프레임워크, Darwin 파일시스템 API와
시스템 SQLite를 사용합니다. [제3자 고지](../THIRD_PARTY_NOTICES.md#한국어)를 참고하세요.

### 저장·복원 흐름

선택 폴더와 볼륨을 확인하고 계획별 잠금으로 동시 쓰기를 막습니다. 기존 완료·미완료
기록과 원본 메타데이터를 비교해 재사용할 내용을 찾습니다. 변경 없는 원본까지 매번
전체 바이트를 다시 해시하는 방식은 아닙니다. 새로 읽는 내용은 SHA-256 키로 저장하고
같은 계획 안의 동일 내용을 공유합니다. 작은 내용은 exFAT에서 SQLite에 묶을 수 있습니다.

이어받기 기록을 남기면서 복사하고 변경 파일은 재시도합니다. 소켓·파이프·사라진 항목은
별도로 처리합니다. 용량 부족·대상 분리 시 중단하고 복사한 내용은 보존합니다.
백업 성공 후에만 완료 목록을 만들고 보관 정책을 적용합니다.

위 저장 구조의 `manifest.json`은 전체 파일 목록이고 `.objects`·SQLite는 공유 내용입니다.
초기 프로젝트 이름에서 남은 `Toolkit Backups` 폴더와
`~/Library/Application Support/FolderToolkit/plans.json` 설정 경로는 기존 설치를 유지하기
위한 것으로 제조사 Toolkit 저장 형식과의 호환성을 뜻하지 않습니다. 날짜 폴더만 떼어
보관하거나 공유 내용을 수동으로 지우지 마세요.

복원은 목록의 경로·중복·내용 키·링크를 검증하고 새 임시 결과에 파일을 씁니다.
해시와 메타데이터 처리가 끝나면 완료 폴더로 바꿉니다. 예전 버전을 순서대로 적용할
필요는 없지만 선택한 버전이 참조하는 공유 내용은 모두 있어야 합니다. 원래 위치
옵션도 원본 옆의 별도 폴더를 만들며 원본 덮어쓰기는 제공하지 않습니다.

SHA-256은 기록된 값과 내용의 일치 여부를 검사하며 암호화·작성자 인증 서명은 아닙니다.
악의적인 저장소 변조를 막는 보안 보관함은 아닙니다. 폴더 전체를 한순간에 고정하지
않으므로 실시간 데이터베이스 등은 앱을 닫거나 해당 프로그램의 일관성 있는 내보내기를
먼저 사용하는 편이 좋습니다.
