# Language support / 언어 지원

## English

English (`en`), Korean (`ko`), Japanese (`ja`), Simplified Chinese (`zh-Hans`) and
Spanish (`es`) are bundled. Each has 310 matching app string keys and five macOS
permission descriptions. The default is **System language**; manual selection in
**Settings → App → Language** persists across restarts.

Automatic selection uses the primary macOS language rather than country/region
or the second preferred language. Regional variants map to a supported base
language; unsupported languages fall back to English. Chinese variants currently
use the Simplified pack, including Traditional-Chinese system locales.

App text updates immediately; native menus/dialogs may require restart.
Names, user paths and unknown original diagnostics are preserved. Dates, numbers
and sizes use the selected locale. The setting affects this app, not the Mac's
global language. Resources are loaded from the installed app bundle.

Tests check keys/placeholders, primary-language fallback, overrides/defaults,
restart persistence, name/path preservation and actual fixture backup/verify/
restore in each language. UI changes were also checked in the installed app.
Translations were written in context with AI assistance; external native-speaker
review has not been obtained. Contributions improving natural wording are welcome.

## 한국어

영어·한국어·일본어·중국어 간체·스페인어를 내장합니다. 언어별 앱 문구 310개와 macOS
접근 권한 설명 5개가 있습니다. 기본값은 **시스템 언어 사용**이고 **설정 → 앱 → 언어**에서
강제로 선택하면 재실행 뒤에도 유지됩니다.

국가·지역이나 두 번째 선호 언어가 아닌 Mac의 첫 언어로 결정합니다. 지원 언어의 지역
변형은 같은 언어로 처리하고 미지원 언어는 영어를 사용합니다. 중국어 번체 시스템도
현재 간체 팩으로 표시합니다. 번체 팩은 포함하지 않았습니다.

앱 문구는 즉시 바뀌고 기본 메뉴·대화상자는 재실행이 필요할 수 있습니다. 사용자 이름·
경로·알 수 없는 원문 진단은 유지하고 날짜·숫자·용량은 선택 언어에 맞게 표시합니다.
Mac 전체 언어는 바꾸지 않으며 리소스는 설치 앱에 포함됩니다.

키·치환 인자, 자동 선택·미지원 언어, 수동 설정·기본값·재실행 유지, 이름·경로 보존과
언어별 실제 임시 백업·검증·복원을 검사했습니다. 설치 앱에서 언어 전환도 확인했습니다.
UI 맥락에 맞춰 AI 지원으로 작성했으며 외부 원어민 감수는 받지 않았습니다.
