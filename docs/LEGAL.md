# License, references and provenance / 라이선스·참고 자료·개발 경위

[English README](../README.md) · [한국어 안내](../README.ko.md)

## English

### License and price

Folder Backup is free to download and use. Its original source code and
project-created artwork are released under the [MIT License](../LICENSE).
MIT permits use, modification, redistribution and commercial use, subject to
preserving the copyright/license notice. The exact English license controls;
this explanation is not a replacement. MIT provides the software without warranty
and limits liability as stated in that license, subject to applicable law.

Free availability is the project's distribution choice. MIT also permits others
to sell their own copies; it does not impose a permanent zero-price rule on forks.

### REA reference work and independent implementation

**REA (Reverse Engineer Anything) was used to study LaCie/Seagate Toolkit's
features and workflows as references. The original program's code was not copied;
Folder Backup was implemented separately in Swift.**

The research included installer/application metadata, packaged UI resources,
observing the Mac interface, official backup/restore documentation, and the
vendor's open-source disclosure bundle. The inspected bundle listed third-party
libraries, not an available source project for Toolkit's proprietary backup engine.
The Windows backup behavior was researched from official documentation; the
Windows app was not executed as part of that comparison.

The public project contains its own backup engine, UI implementation, storage
format, translations and folder/check artwork. It does not ship the vendor's
installer, executable, decompiled source, original UI artwork, extracted icons or
third-party source archives from that disclosure bundle. Early local prototypes
used vendor artwork for reference; that artwork and development history are not
part of this public source release. This describes the actual development process,
not a claim that a formal independent clean-room legal process was performed.

The app is not a patch, official port, vendor-approved replacement or
format-compatible reader. It cannot import or restore the vendor's Toolkit
archives. Functional inspiration does not promise identical behavior.

### Third-party rights and remaining boundaries

- Folder Backup is not affiliated with, sponsored by or endorsed by Seagate,
  LaCie or Apple. Their names identify referenced products/platforms only.
  Third-party trademarks and logos remain their respective owners' property.
- MIT covers the project's original contributions, not third-party names,
  documentation, SDKs, frameworks, system symbols or vendor materials. Links
  are references, not a relicensing or redistribution of their contents.
- No third-party Swift package or vendor-disclosure library source is bundled.
  The app links platform libraries; see [third-party notices](../THIRD_PARTY_NOTICES.md).
  If future changes incorporate third-party code, its actual license must be
  reviewed and its notices/obligations followed. A GPL-labeled disclosure does
  not authorize relicensing any code copied from it as MIT.
- REA inspection and a no-copy statement are not a legal clearance. No independent
  review of patents, worldwide trademark availability, trade dress, vendor EULAs
  or reverse-engineering restrictions has been obtained. No assurance of absence
  of every legal claim is made; a rights concern should identify the specific
  material and basis through the repository's contact/issue channel without
  exposing private data.
- The current binary is Developer ID signed and not notarized, not Apple-certified or
  App Store reviewed. Publishing on GitHub does not confer Apple approval.
  Apple tools/services remain subject to their [applicable agreements](https://developer.apple.com/support/terms/).
- Backup only files you have authority to handle. This app does not encrypt
  backups, grant access rights to somebody else's files, or provide compliance
  certification. See [Privacy](../PRIVACY.md).

Implementation, localization and documentation used AI assistance. The recorded
engineering tests are not independent security certification or legal review.

### Reference documents

These were consulted for product behavior or platform usage, not copied into
the program. External documents may change after this release.

- [Seagate: Backup Activity (Windows Only)](https://www.seagate.com/manuals/software/toolkit/backing-up/)
- [Seagate: Restore Activity (Windows Only)](https://www.seagate.com/manuals/software/toolkit/restore-files/)
- [Seagate: Backup and Mirror differences](https://www.seagate.com/support/kb/backup-and-mirror-differences-faq/)
- [Seagate: Toolkit support and open-source disclosure](https://www.seagate.com/support/software/toolkit/)
- [Apple: Safely open apps on your Mac](https://support.apple.com/en-us/102445)
- [Apple: Distribution outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
- [SQLite: Copyright and public-domain statement](https://www.sqlite.org/copyright.html)
- [REA project](https://github.com/morluto/rea) — analysis tool reference, not an app dependency.

## 한국어

### 무료 배포와 MIT

Folder Backup은 무료로 내려받아 사용할 수 있습니다. 독자 작성 소스와 직접 만든 그림은
[MIT 라이선스](../LICENSE)로 공개합니다. 저작권·라이선스 고지를 유지하면 이용·수정·
재배포·상업적 사용이 가능합니다. 정확한 조건은 영문 LICENSE 원문을 따릅니다.
무보증·책임 제한도 해당 라이선스와 적용 법률의 범위에서 해석해야 합니다.

무료 배포는 이 프로젝트의 운영 방침입니다. MIT 자체가 모든 파생본의 가격을 무료로
제한하는 것은 아니므로 다른 사람이 유료로 재배포하는 것도 라이선스상 허용됩니다.

### REA 참고 및 코드 비복사

**REA(Reverse Engineer Anything)를 통해 LaCie/Seagate Toolkit의 기능과 사용 흐름을
참고했습니다. 원본 프로그램의 코드는 복사하지 않았으며 Folder Backup은 별도 Swift
코드로 구현했습니다.**

설치·앱 메타데이터, 패키지 UI 리소스, Mac 화면, 공식 백업·복원 문서와 제조사가 제공한
오픈소스 고지 묶음을 조사했습니다. 조사한 묶음에는 서드파티 라이브러리가 나열되어
있었으며 Toolkit 자체 백업 엔진의 공개 소스 프로젝트는 확인되지 않았습니다.
Windows 동작 비교는 공식 문서에 근거하며 Windows 앱을 실행해 확인한 것은 아닙니다.

공개본의 백업 엔진·UI 구현·저장 형식·번역·폴더/체크 그림은 별도로 작성했습니다.
제조사 설치 파일·실행 파일·디컴파일 소스·원본 UI 그림·추출 아이콘·고지 묶음의 라이브러리
소스는 배포하지 않습니다. 초기 로컬 시제품에서 참고용으로 쓰인 제조사 그림과 개발
이력도 공개본에 포함하지 않았습니다. 이는 실제 경위에 대한 설명이며 법적으로 독립된
클린룸 절차를 거쳤다는 주장은 아닙니다.

공식 포트·패치·제조사 인증 대체품이나 호환 리더가 아닙니다. 제조사 Toolkit 백업을
가져오거나 복원하지 못하며 원본과 모든 동작이 같다고 보장하지 않습니다.

### 제3자 권리와 남은 범위

- Seagate·LaCie·Apple의 후원·제휴·승인을 받은 프로젝트가 아닙니다. 이름은 참고 제품과
  플랫폼을 식별하기 위해 적었으며 제3자 상표·로고의 권리는 해당 권리자에게 있습니다.
- MIT는 독자 기여물에 적용됩니다. 제3자 상표·문서·SDK·프레임워크·시스템 기호·원본 자료를
  MIT로 바꾸거나 그 이용 권한까지 부여하지 않습니다. 링크도 원문 재배포를 뜻하지 않습니다.
- 외부 Swift 패키지나 제조사 고지 묶음의 소스를 동봉하지 않습니다. 시스템 라이브러리
  사용은 [제3자 고지](../THIRD_PARTY_NOTICES.md#한국어)에 정리했습니다. 향후 외부 코드를
  포함하면 실제 라이선스와 고지 의무를 별도 검토해야 하며 GPL 코드를 복사한 뒤 MIT로
  바꿔도 된다는 의미는 아닙니다.
- REA 조사·비복사 표기는 법적 면책이나 무침해 인증이 아닙니다. 특허·세계 각국 상표 등록·
  디자인·제조사 EULA·역분석 제한에 대한 독립적인 법률 검토는 받지 않았습니다.
  권리 문제가 있다고 판단하면 해당 자료와 근거를 저장소 문의 경로로 알려 주세요.
  공개 이슈에 민감한 자료를 첨부하지 마세요.
- 현재 바이너리는 Developer ID 서명·미공증 베타이며 Apple 인증·App Store 심사를 받은 제품이
  아닙니다. GitHub 공개가 Apple 승인을 뜻하지 않습니다. Apple 개발 도구·서비스에는
  [해당 약관](https://developer.apple.com/support/terms/)이 별도로 적용됩니다.
- 처리 권한이 있는 파일만 백업해야 합니다. 백업 암호화·타인 파일 접근 권한 부여·법규
  준수 인증은 제공하지 않습니다. [개인정보 처리](../PRIVACY.ko.md)를 확인하세요.

코드·번역·문서 작성에는 AI 지원을 활용했습니다. 엔지니어링 검사를 독립 보안 인증이나
법률 검토로 해석하면 안 됩니다. 참고한 공식 문서는 위 영문 절의 링크에서 확인할 수 있습니다.
