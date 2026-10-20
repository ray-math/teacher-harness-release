# 변경에 맞는 유지보수 검사

공통 실행 코드·설정의 동작을 바꿀 때만 사용한다. 문구·링크·스킬 설명만 바꾸면 형식·링크·대표 요청 판단으로 끝낸다. 일반 문서 제작에는 이 표를 적용하지 않는다.

변경된 기능에 해당하는 기본 검사만 고른다. 추가 검사는 그 열의 조건에 해당할 때 선택한다. 여러 행에 같은 명령이 나와도 한 번 실행한다. 같은 코드·입력·환경에서 이미 통과한 결과는 재사용하며, 실패 수정이나 의존 변경 때 영향받는 검사만 재실행한다. 서로 다른 경계 검사를 단순히 비슷하다는 이유로 생략하지 않는다.

| 변경 대상 | 기본 검사 | 추가 검사 조건 |
|---|---|---|
| 접수·업무별 등록·게시 흐름 | `Test-FixedCore.ps1`, `Test-HumanDeliveryFlow.ps1` | 현재 파일 보존/롤백 변경이면 `Test-WorkStorage.ps1` |
| 반복 업무 분류·공통 자료·확정 처리 방법 | `Test-WorkGroups.ps1` | 자료 탐색 실행기 변경이면 `Test-ExplicitPriorFolders.ps1` |
| 공통 도구 폴더 이름·Codex 경로 변경 | `Test-WorkToolsRename.ps1` | 실제 이동 뒤 런타임 확인; 앱 프로젝트 열기는 사용자 확인 |
| 보관함 경로 선택·연간 이동 | `Test-HumanCabinetRoot.ps1` | 문서 게시도 바꾸면 `Test-FixedCore.ps1` |
| 업무 저장 경계·번호 경로·내부 수정 이력 | `Test-WorkStorage.ps1`, `Test-HumanDeliveryFlow.ps1` | 변환·계약·Python 실행기의 경로 연계도 바꾸면 `Test-WorkStorageAdapters.ps1` |
| 업무흐름 순서·배치 | `Test-WorkWorkflowLayout.ps1` | 근거 해시·권위·실패 복원도 바꾸면 `Test-WorkWorkflowSafety.ps1` |
| 기준자료 선택·탐색·재사용 | `Test-ExplicitPriorFolders.ps1` | 접수까지 바꾸면 `Test-FixedCore.ps1` |
| HTML·TXT 자동 생성 기본값 | `Test-FixedCore.ps1` | 명시적 HTML 게시도 바꾸면 `Test-ConsoleContentPublication.ps1` |
| 보고 스키마·보고 게시·TXT 게이트 | `Test-ConsoleContentPublication.ps1` | 생성된 브라우저 동작도 바꾸면 `Test-ConsoleBrowserLogic.cjs` |
| 콘솔 생성기·갱신 | `Test-ConsoleRefresh.ps1` | UI 스크립트는 `Test-ConsoleBrowserLogic.cjs`, 구조화 업무흐름은 해당 위 행 |
| 파일 열기 실행기·응답 | `Test-NativeOpenAcknowledgement.ps1` | 경로 허용 검증도 바꾸면 `Test-HumanWorkOpenNativeSafety.ps1` |
| 설치된 실행 코드만 갱신 | `Test-PortableRuntimeOnly.ps1` | 실제 배포에서는 설치본 해시와 업무문서·설정 보존 확인 |
| 보관함 최초 설치·이동 | `Test-PortableCabinet.ps1` | 접수 연계도 바꾸면 `Test-CabinetLifecycle.ps1` |
| HWPX 실행기·버전·MCP 연결 | `Start-HwpxMcpWindows.ps1 -CheckOnly`, `test_hwpx_dynamic_launch.py` | 설치·등록 코드 변경 시 `test_hwpx_mcp_install.py --powershell <실행기> --codex <CLI>`로 TEMP 설정에서 최초 등록·재사용·충돌 보존·서버 기동 실패를 검사. 앱 설정 변경 시 `--installed-config <config.toml>`로 등록한 명령의 연결도 검사. 편집 런타임 변경은 TEMP 합성 편집·재열기 추가; 새 세션 도구 노출은 별도 확인 |
| 선택적 입력 루트 누락·업무 이동 재접수 | `test_workflow_path_resume.py` | TEMP 합성 보관함에서 MCP 읽기·루트 경계·같은 cycle 재접수·완료 재검증·게시 재사용 확인 |
| ODT 의존성·생성 실행기 | 개인 `official-odt-draft/scripts/run_odt.py --self-test` | 스킬 전용 고정 의존성 사용, 신규 세 양식 생성·재열기·덮어쓰기 거부 |
| XLSX 미리보기 실행기 | `test_xlsx_preview_runtime.py --node <번들 Node> --node-modules <번들 패키지>` | TEMP 합성 파일 작성·수정·계산·별도 Excel 렌더·정상 종료·원본 보존; COM이 가능한 권한 실행 경로 사용 |
| 명단 추출·diff·대조 로직 | `collect-hwpx-rosters/test_collection.py` | 파일 입출력도 바꾸면 선택한 합성 입력으로 실행기 확인 |
| 전체 문서 병합 실행기 | 합성 입력 병합과 해당 영수증 | 변경한 부분의 입력 보존·순서·필수 재열기·게시 게이트 |
| 양식/게시 게이트 자체 | `Test-FormFirstAndConsole.ps1`의 영향받는 사례 | 변경된 게이트의 실패·통과 사례; 무관한 콘솔 검사로 확대하지 않음 |
| 내용·서식·시각 검사 범위 게이트 | `Test-DocumentScope.ps1`, `Test-FixedCore.ps1`, `test_document_scope_runtime.py` | 게시 경계를 바꾸면 `Test-DocumentScopePublication.ps1`; 실제 학교 문서로 시험하지 않음 |
| 승인된 양식의 내용 채우기 용량 | `Test-TemplateFillCapacity.ps1`, `Test-DocumentScope.ps1` | 직접 셀 좌표와 문단 슬롯을 합성 입력으로 검사; 앵커·서식 변경 작업은 실제 결과 내용 확인 |
| 기록 기반 시간·토큰 집계 | `test_measure_workflow_usage.py` | 중복 usage·캐시 포함 관계·미완료 구간·이미지 제외·시각 범위를 합성 JSONL로 확인 |
| 구조·필수 도구 존재 | `Test-HwpxWorkspace.ps1 -StructureOnly` | 이 검사는 실제 업무문서를 읽지 않음 |

명령은 `.agent/shared/` 기준이다. PowerShell은 Windows PowerShell 5.1, Python/Node는 검사에서 지정한 기존 실행기를 사용한다. 합성 fixture와 영수증은 시스템 임시폴더에 두며 실제 학교 파일·등록·현황판으로 시험하지 않는다. 유지보수용으로 복제하는 fixture에는 변경한 공통 도구의 현재 의존 파일을 포함한다.

실패는 기능 결함, 오래된 fixture/기대값, 환경 문제를 구분한다. 기대값은 사용자 요구와 실제 계약에 근거해 수정하고, 게이트를 낮춰 통과시키지 않는다. 의존성이 없으면 해당 제한을 보고하며 무관한 설치로 확대하지 않는다.

결과는 실제 수행한 검사·결과·미검증 범위를 채팅으로 보고한다. 네이티브 실행·정적 브라우저 로직 검사는 실제 브라우저 클릭이나 문서 외관 검사와 구별한다. 관련 검사가 통과하면 요청된 단계에서 끝낸다.
