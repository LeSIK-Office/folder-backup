# Third-party notices / 제3자 고지

## English

The project has no third-party Swift package dependencies and does not vendor
third-party library source code. This is a dependency inventory, not a relicensing
of platform software.

| Component | How used | Rights / reference |
|---|---|---|
| SwiftUI, AppKit, Foundation, Combine, CryptoKit, ServiceManagement, Darwin and related system libraries | Native macOS UI, hashing, lifecycle and filesystem APIs; linked from macOS | Apple/platform terms; [Apple agreements](https://developer.apple.com/support/terms/) |
| Swift runtime | System runtime linked by Apple's Swift toolchain | Distributed with the platform/toolchain under its applicable terms; not re-licensed by this project's MIT notice |
| SQLite | macOS system `libsqlite3`, accessed through `SQLite3` for packed content objects | SQLite's deliverable code is [public domain](https://www.sqlite.org/copyright.html); Apple's system build remains part of the platform distribution |
| SF Symbols | System-provided UI symbols rendered through Apple APIs | Apple platform/design-resource terms; no extracted vendor icon pack is distributed |
| Folder/check app icon | Drawn by `scripts/generate-icon.swift` using project-created geometry | Project artwork under [MIT](LICENSE) |

LaCie/Seagate Toolkit and its disclosed third-party libraries were research
references through REA, not runtime dependencies. Their code was not copied into
this app. Their installer, binary, extracted graphics and source archives are not
shipped. See [provenance](docs/LEGAL.md).

System dependencies can change with macOS. Adding bundled libraries or other
third-party material requires updating this inventory and complying with the
actual upstream license. The MIT license does not override those obligations.

## 한국어

외부 Swift 패키지 의존성이나 동봉한 서드파티 라이브러리 소스는 없습니다. 위 표는 사용
구성 목록이며 플랫폼 소프트웨어를 MIT로 재라이선스하는 문서가 아닙니다.

Apple 프레임워크·Darwin·Swift 런타임은 macOS와 개발 도구가 제공하는 시스템 구성 요소를
사용합니다. SQLite는 macOS의 `libsqlite3`에 연결하며 SQLite 원본 배포 코드는 퍼블릭
도메인입니다. macOS의 시스템 배포 조건은 별도로 유지됩니다. SF Symbols는 Apple API로
표시하며 추출한 제조사 아이콘 묶음을 동봉하지 않습니다. 앱 아이콘은 생성 스크립트에서
직접 그린 폴더·체크 그림이며 프로젝트 MIT 라이선스를 적용합니다.

Toolkit과 제조사 고지 묶음의 라이브러리는 REA 조사 참고 자료이지 실행 의존성이 아닙니다.
해당 코드를 복사하지 않았고 설치 파일·실행 파일·추출 그림·소스 압축파일도 배포하지 않습니다.
[개발 경위](docs/LEGAL.md#한국어)를 확인하세요. 향후 외부 구성 요소를 추가하면 이 목록과
실제 라이선스 고지를 함께 갱신해야 합니다.
