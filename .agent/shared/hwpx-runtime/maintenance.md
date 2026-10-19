# HWPX 런타임 유지보수

런타임이나 연결 설정의 설치·복구·업데이트가 요청되었거나 해당 구성요소를 수정할 때만 적용한다. 일반 문서 작업은 [SKILL.md](SKILL.md)의 검증된 실행 경로를 사용한다.

`Start-HwpxMcpWindows.ps1 -CheckOnly`로 고정 버전과 capability를 확인한다. `Install-HwpxNativeConnection.ps1`은 검증된 Windows Python으로 `hwpx_mcp_launch.py`를 시작하도록 설정한다. 이 실행기는 연결을 시작할 때 `delivery-system.json`의 현재 경로를 읽으므로 보관함·입력 폴더 경로를 앱 설정에 중복 고정하지 않는다. 플러그인 캐시의 Bash 파일은 수정하지 않는다. 앱 안의 새 연결은 재연결 후 확인하며 독립 MCP 검사 통과를 현재 세션 도구 노출로 표현하지 않는다.

전체 검증 패키지 버전은 [requirements-verified.txt](requirements-verified.txt)에 있다. 캐시 복구나 업데이트는 별도 후보를 구성해 고정 Python의 `test_hwpx_native_runtime.py`로 연결·읽기·저장을 검증한 뒤 spec과 연결을 함께 바꾼다. 편집 어댑터의 버전 가드도 실제 회귀 검증 후에만 갱신한다. 실패하면 직전 검증 런타임/설정을 유지한다.

합성 자료와 진단은 시스템 임시폴더에서 처리한다. 하네스에 작업별 복구 폴더를 만들지 않는다. 검사는 [유지보수 점검 경로](../../../.agents/skills/workspace-maintenance/references/checks.md)에서 변경한 구성요소에 맞춰 선택한다.
