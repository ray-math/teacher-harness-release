# 설치·설정·점검

배포 폴더 전체를 전달하면 됩니다. `.agent`, `.agents`와 공통 실행 코드를 함께 유지하며, 스킬을 별도로 설치하거나 개인 `~/.codex/skills`로 복사하지 않습니다. 공유할 때 `.agent/private/`는 반드시 제외합니다. `.gitignore`는 탐색기 복사나 ZIP 압축을 막지 않으므로 개인자료가 들어 있는 폴더는 제외합니다. 개인 업무자료·가상환경·설치 캐시·개인 Codex 설정도 배포하지 않습니다.

이 안내는 Windows용입니다. `teacher-harness-test`에서 기능을 수정·합성 검증하고 검증한 변경을 `teacher-harness-release`에 반영합니다. 실행 명령은 Windows PowerShell 5.1을 사용하고, 경로는 자신의 컴퓨터에 복사한 배포 폴더를 기준으로 찾습니다.

## 1. 프로젝트에서 “설치해줘”라고 요청

GitHub 배포본은 [저장소](https://github.com/ray-math/teacher-harness-release)의 **Code → Download ZIP** 또는 [최신 배포본 ZIP 다운로드](https://github.com/ray-math/teacher-harness-release/archive/refs/heads/main.zip)로 받습니다. ZIP 전체를 자신의 컴퓨터에 압축 해제하고, `AGENTS.md`, `Install.ps1`, 숨김 폴더 `.agent`, `.agents`가 함께 있는 폴더를 프로젝트로 선택합니다. 공유 폴더로 받은 경우에는 기존처럼 폴더 전체를 자신의 컴퓨터에 복사해 사용합니다.

받는 사람은 Codex를 설치하고 로그인한 뒤, 자신의 컴퓨터에 복사한 배포 폴더를 프로젝트로 엽니다. 프로젝트 채팅에서 다음과 같이 요청합니다.

> 설치해줘.

Codex는 이 안내를 읽고 다음 순서로 진행합니다.

1. `Install.ps1 -CheckOnly`로 현재 경로·런타임 파일·설치 도구·Codex CLI 사용 가능 여부를 읽기 전용으로 확인합니다.
2. 기존 설정을 재사용해 `Install.ps1`을 실행합니다. 업무·받은자료 경로를 적용하고, 필요한 `uv`와 HWPX·ODT 실행 환경을 설치·검사합니다.
3. Codex CLI를 찾을 수 있으면 HWPX MCP 연결을 기본으로 등록합니다. 기존 Codex 설정을 보존하고, 설정 파일이 아직 없으면 Codex CLI로 만듭니다. 동명의 동일 연결은 재사용하고 다른 연결은 덮어쓰지 않습니다. 등록된 명령을 실제로 실행해 MCP 초기화·필수 도구·상태 응답도 확인합니다.
4. 완료한 단계와 실패·미검증 항목, 사람이 처리해야 할 단계를 채팅으로 보고합니다. MCP 등록 뒤에는 새 Codex 채팅에서 실제 도구 노출·호출을 확인합니다.

설치 요청 자체가 위 설정·다운로드·연결·검사 작업의 요청입니다. 같은 설정이나 실행 단계를 다시 승인받기 위한 질문은 하지 않습니다. 일반 문서 작성 요청에서는 공통 런타임을 자동 설치·갱신하지 않습니다.

이미 설정한 업무·받은자료 경로나 Codex 설정은 다시 묻지 않고 사용합니다. 처음 사용하는 배포본의 기본 위치는 `../업무`, `../받은자료`, 테스트본은 `../테스트자료/업무`, `../테스트자료/받은자료`입니다. 상대경로는 이 배포 폴더 기준이며 현재 값은 `.agent/index/delivery-system.json`에서 읽습니다. 경로가 유효하지 않거나 사용자가 다른 위치를 원하면 필요한 경로만 확인해 적용합니다. 설정은 원본 학교자료나 기존 업무를 이동시키지 않습니다.

다른 위치를 원하면 요청에 함께 적을 수 있습니다.

> 설치해줘. 업무는 E:\교사업무\업무, 받은자료는 E:\교사업무\받은자료를 써줘.

## 2. 직접 실행하기

배포 폴더에서 다음 두 명령을 순서대로 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -CheckOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

`-CheckOnly`는 읽기 전용이며 설치·설정 저장·MCP 등록·업무폴더 생성을 하지 않습니다. 점검에서 런타임이 없다는 결과는 배포본의 문서와 스크립트가 누락됐다는 뜻과 다릅니다. 기본 실행은 경로를 저장하고 대상 폴더를 만듭니다. `uv`가 없으면 공식 `winget` 패키지의 사용자 범위 설치를 시도한 뒤 고정 HWPX·ODT 의존성을 설치합니다. 이미 준비된 실행 환경은 확인해 사용합니다.

다른 업무·받은자료 위치를 지정하려면 다음과 같이 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -CabinetRoot 'E:\교사업무\업무' -IncomingRoot 'E:\교사업무\받은자료'
```

MCP 등록을 생략하고 경로·실행 환경만 준비하려면 다음과 같이 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -SkipMcp
```

`-SkipMcp` 결과는 MCP 연결 성공으로 보고하지 않습니다. 자연어로 “MCP 연결은 생략하고 설치해줘”라고 요청해도 같은 옵션을 적용합니다.

## 3. 자동 처리와 사람 단계의 경계

`Install.ps1`은 이 컴퓨터의 프로젝트 실행 환경을 준비합니다. HWPX의 고정 의존성은 `.agent/shared/hwpx-runtime/requirements-verified.txt`, 설치 위치·버전 설정은 `.agent/index/hwpx-runtime.json`에서 관리합니다. ODT 의존성은 프로젝트의 `official-odt-draft/.deps`에 설치하고 Python·의존성 경로를 `.agent/index/odt-runtime.json`에 기록합니다. 설치된 가상환경을 다른 컴퓨터에 그대로 복사하지 않습니다.

Codex CLI가 없으면 준비할 수 있는 경로·런타임 작업을 마친 뒤 MCP 등록이 미검증임을 보고합니다. 같은 이름의 `hwpx` 연결이 다른 명령·인수·환경을 사용하거나 비활성화·필수 도구 제한 상태이면 기존 연결을 보존하고 그 등록만 중단해 충돌 내용을 보고합니다. 다른 Codex 연결·설정과 전역 스킬은 보존합니다. 기존 설정에 연결을 추가할 때 원본을 TEMP에 백업하고 위치를 설치 결과에 기록합니다. MCP 등록 확인(`mcpRegistrationVerified`), 등록된 서버의 실제 기동·상태 확인(`mcpTransportVerified`), 현재 채팅의 도구 노출 확인은 별도 결과입니다. 서버가 시작되지 않으면 등록만 성공했더라도 설치 결과를 주의 필요로 보고합니다.

`python-hwpx`는 문서 읽기·수정·저장의 엔진이고, `python-hwpx-automation`은 그 엔진을 사용하는 자동화·CLI·MCP 계층입니다. MCP를 사용해도 서버 내부에서 두 패키지가 필요합니다. 자동화 패키지 7.0.4는 `python-hwpx>=6.3.0,<7`을 요구하며, 이 배포본은 재현성을 위해 엔진도 6.3.0으로 고정합니다. 두 줄은 동일 라이브러리의 중복 설치가 아닙니다.

Codex 설치·로그인, 한컴오피스 설치·라이선스, 네트워크 또는 시스템 권한은 사람이 처리해야 할 수 있습니다. `winget`·네트워크를 사용할 수 없거나 권한이 막히면 실패한 단계와 필요한 조치를 보고하며 설치 완료로 표현하지 않습니다. `uv`의 수동 설치가 필요하면 [Astral 공식 설치 안내](https://docs.astral.sh/uv/getting-started/installation/)를 사용합니다.

한컴오피스는 HWP 변환·한글 네이티브 병합·자동화·페이지 확인에 필요할 수 있습니다. XLSX의 Excel 미리보기는 Excel과 COM 실행 환경을 요구합니다. 보안 모듈 DLL은 배포본에 포함하지 않습니다. 네이티브 병합을 사용할 경우 공식 한컴 보안 모듈을 별도로 준비하고 [한컴 네이티브 안내](.agent/shared/hancom-native/README.md)의 설치 조건과 해시 검사를 따릅니다.

HWPX 전문 플러그인을 사용할 경우 [HWPX 유지관리자의 안내](https://github.com/airmang/hwpx-plugins)를 확인합니다. 플러그인 지침·로컬 Python 런타임·MCP 연결은 각각의 구성요소이며 하나의 설치 결과로 모두 완료됐다고 보고하지 않습니다.

## 4. 개별 설정·설치가 필요한 경우

`Install.ps1`은 전체 설치의 진입점이며 `Setup.ps1`은 필요한 구성요소만 실행하는 도구입니다. 아래 명령은 전체 설치 대신 개별 작업을 요청할 때 사용합니다. `Setup.ps1`의 런타임 옵션은 미리 설치한 `uv`가 필요합니다.

```powershell
# 상태만 확인
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -CheckOnly

# 현재 설정의 업무·받은자료 경로 적용
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1

# HWPX 또는 ODT 실행 환경만 설치
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -InstallRuntime
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -InstallOdt
```

ODT 설치 후에는 [공문 스킬](.agents/skills/official-odt-draft/SKILL.md)의 실행 절차를 사용합니다. 먼저 사용자가 지정한 기존 초안/양식을 열어보고, 등록된 현재본 또는 명시적으로 선택한 이전 문서도 기준본으로 활용합니다. 빈 ODT 양식은 예제 assets이며 사용자가 선택하기 전에는 기본 양식이 아닙니다. 초안과 양식이 모두 없거나 읽을 수 없거나 선택이 모호하면 관련 작성을 멈추고 필요한 자료를 요청합니다. 런타임 설치가 새 양식 작성 허가를 뜻하지 않습니다.

업무현황 HTML·파일 열기 프로토콜·보관함 콘솔 설치는 별도 명시적 요청에 따라 필요한 실행기만 사용합니다. 프로젝트 지침은 `AGENTS.md`, 스킬은 `.agents/skills/`에서 관리하고 필요한 스킬과 참고자료만 읽습니다.

## 5. 설치 뒤 실제 기능 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Test-HwpxWorkspace.ps1 -StructureOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Start-HwpxMcpWindows.ps1 -CheckOnly
```

첫 명령은 구조 확인, 둘째는 설정된 HWPX 실행 환경 확인입니다. 설치 과정에서 이미 실행한 검사는 그 결과를 사용합니다. 실제 학교자료 대신 합성 문서로 읽기·편집·저장·재열기를 확인한 후 사용합니다. 한컴 네이티브 처리와 페이지 렌더는 그 기능을 사용할 컴퓨터에서 별도로 검증합니다.

설정·패키지 설치·구조 검사·MCP 등록·현재 채팅의 도구 호출·한글 자동화·페이지 렌더의 결과를 각각 보고합니다. 확인하지 못한 기능은 미검증으로 남깁니다. MCP가 노출되지 않으면 [로컬 HWPX 실행 안내](.agent/shared/hwpx-runtime/SKILL.md)의 지원 경로와 제한을 확인합니다. 오류가 나면 해당 기능과 의존성만 진단하고 무관한 프로그램 설치로 확대하지 않습니다.

### 연결 재사용 성능 비교

실제 학교자료 없이 같은 합성 문서의 본문·표를 읽어 비교합니다. 고정 HWPX 런타임의 Python으로 아래 도구를 실행합니다.

```powershell
$runtime = & .agent/shared/Get-HwpxRuntime.ps1
& $runtime.Python -B .agent/shared/benchmark_hwpx_transport.py --output "$env:TEMP/hwpx-benchmark-new.json" --sequence-only --sequence-batches 6 --sequence-repetitions 3 --timeout 420
```

기존 출력 파일은 덮어쓰지 않으므로 새 결과 경로를 지정합니다. 합성 문서는 TEMP에 만들고 검사 뒤 제거합니다. 현재 로컬 읽기 실행기도 같은 MCP 서버를 쓰며 배치마다 연결을 새로 엽니다. 이 검사는 배치별 새 연결과 한 연결 재사용을 비교하고 기동·초기화·종료 시간, 결과 내용 동등성과 원본 보존을 함께 확인합니다. `--sequence-only`를 빼면 매 호출·매 배치·이미 열린 연결의 워밍업 후 지연도 함께 측정합니다. 결과는 연결 재사용 효과이며 모델 응답·토큰 사용량·한컴 렌더링·문서 편집 품질의 개선율로 해석하지 않습니다.

## 제공자료 보관과 개인 설정

분류번호대·반복 업무의 자료와 처리 방법은 해당 연간 업무 묶음에서 정합니다. 특정 과목과 개인업무에 고정된 번호는 기본 설정에 없습니다.

사용자가 파일을 제공하면 `Receive-TeacherHarnessInputs.ps1 -SourceFile <접근 가능한 로컬 파일들>`로 설정된 받은자료에 원본 사본을 자동 보관합니다. 문서 접수의 `-UserProvidedFile`도 같은 보관을 수행합니다. SHA256 확인·같은 내용 재사용·같은 이름의 다른 내용 보존을 적용하고 원래 파일을 이동하거나 수정하지 않습니다. 접근 불가 첨부는 보관됐다고 보고하지 않고 접근 가능한 경로를 요청합니다. 파일 감시기 설치는 이 설정에 포함하지 않습니다.

## 업데이트와 이동

공통 코드·지침·런타임 변경은 [유지보수 스킬](.agents/skills/workspace-maintenance/SKILL.md)을 따릅니다. 문서 작업 도중에는 런타임을 갱신하지 않습니다. 고정 의존성을 바꾸면 관련 어댑터·버전 확인·합성 검증을 함께 확인합니다.

배포 폴더를 이동하거나 다른 컴퓨터로 복사한 뒤에는 `Install.ps1 -CheckOnly`로 현재 컴퓨터의 상태를 먼저 확인하고 “이 위치에 다시 설치해줘”라고 요청하거나 `Install.ps1`을 실행합니다. 같은 컴퓨터의 유효한 업무 경로는 재사용합니다. 이전 컴퓨터에만 존재하는 절대경로·가상환경·MCP 연결은 그대로 사용하지 않습니다. 기존의 다른 MCP 연결과 충돌하면 자동으로 덮어쓰지 않습니다. 업무 보관함의 기존 파일을 옮기거나 연결을 바꾸는 작업은 별도 요청 범위로 처리합니다.

연간 업무 묶음은 필요할 때 `2026업무`처럼 보관하고 새 업무 묶음을 시작합니다. 과거 업무의 일정·명단·예외를 다음 연도로 자동 상속하지 않습니다.
