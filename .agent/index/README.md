# 공통 설정

- `delivery-system.json`: 출력 경로와 내부 저장 이름. 강의 기본값은 `pathBase: "desktop"`, `humanCabinet: "Output"`, `outputLayout: "flat"`, `receiveInputs: false`다. 실제 바탕화면의 Output에 번호 파일을 바로 저장하고 받은자료를 만들지 않는다. 내부 이력은 `.ai/`에 둔다. `Install.ps1`은 선택 경로를 저장하며 기존 업무는 이동하지 않는다. 새 옵션이 없는 기존 설정은 업무별 폴더와 받은자료 보관 동작을 유지하고, pathBase가 없으면 하네스 기준 상대경로를 유지한다.
- `hwpx-runtime.json`: 런타임 위치와 원본에서 고정한 패키지 버전. 패키지 자체는 별도 설치한다.

과목·개인업무 번호와 특정 학교 정보는 기본 설정에 없다. 연간 업무 묶음의 `.ai/work-groups/`에 사용자가 확정한 분류와 공통 처리 방법을 저장한다. 개별 업무 등록은 `.ai/work.json`, 별도 자료 선택은 `.ai/reference-scope.json`에 둔다.

선택적 콘솔의 설치 상태·열기 목록은 설치된 업무 보관함의 `.agent/index/`에서 관리한다. `openTargetManifest`는 해당 설치 루트 기준이며 공통 배포본에 학교 파일 목록을 저장하지 않는다.
