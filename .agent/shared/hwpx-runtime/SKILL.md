---
name: hwpx-runtime
description: 이 Windows 작업실의 HWPX 읽기·편집 실행 경로와 MCP 미연결 시 검증된 로컬 대체 경로를 선택한다.
---

# HWPX 실행 경로

한글 파일의 실행 경로만 다룬다. PDF/XLSX 등 다른 형식에는 해당 스킬을 쓰며 HWPX 상태를 확인하지 않는다. 문서별 편집 계약과 전문 안전 검사는 설치된 HWPX 스킬을 따른다.

## 경로 선택

- 현재 작업공간에 설치된 로컬 런타임이 있으면 일반 양식 채우기는 아래 로컬 읽기·편집 경로를 바로 사용해도 된다. MCP 상태 확인을 위해 작성을 지연하지 않는다. 이미 정상 연결된 MCP를 사용할 때만 세션 최초 한 번 상태를 확인하고 재사용한다. 두 경로를 중복 점검하지 않는다.
- 도구가 없으면 아래 로컬 경로를 사용한다. 스킬 설치는 MCP 연결 성공을 뜻하지 않는다. 문서 작업에서 설치·업데이트·Bash 진단이나 무변경 재시작을 반복하지 않는다.
- 연결된 MCP의 허용 루트가 현재 하네스 설정과 달라 `WORKSPACE_OUTSIDE_ROOT`가 발생하면 같은 호출을 반복하지 않는다. 사용자가 선택하여 접수한 자료의 작업 내부 보존 사본이 설정된 출력 경로 안에 있는지 확인한 뒤 설치된 로컬 읽기·편집 실행기를 사용한다. 로컬 실행기는 현재 하네스의 설정을 적용하므로 연결된 서버의 오래된 루트를 바꿀 필요가 없다. 임의로 허용 루트를 넓히거나 파일을 다른 허용 폴더로 옮겨 거부를 피하지 않는다. 로컬에서도 접근 또는 범위 검사가 거부되면 그 원인을 보고한다.
- 경로/버전은 `.agent/index/hwpx-runtime.json`, 문서 접근 루트는 `delivery-system.json`이 정본이다. 캐시는 재생성 가능한 설치물이며 정책·영수증 정본이 아니다.
- 접수한 파일은 읽기 전에 `inputs.json`의 보존 사본 경로와 원본 해시를 확인한다. 사용자 원래 경로가 접근 루트 밖이면 같은 해시의 작업 내부 보존 사본을 읽는다. 강의 기본 설정에서는 별도의 받은자료 폴더를 만들지 않는다. 원본 경로로 먼저 실패시킬 필요가 없으며, 이는 접수가 보관한 사본의 재사용이지 임의 이동이나 루트 확장이 아니다.
- HWP는 선택한 파일만 공식 변환기로 별도 HWPX 사본으로 만든다. 전체 파일 이어붙이기는 [native merge](../hancom-native/WORKFLOW.md)의 전용 경로를 사용한다.

## 필요한 범위만 읽기

MCP와 로컬 읽기에 공통으로 적용한다. 구조 탐색은 `get_document_map(detail="summary", max_preview_chars=80)`에서 시작하고, 작업할 표는 `get_table_text(table_index=...)`, 특정 노드는 `query_document_nodes(selector=..., limit=..., node_depth=..., child_limit=...)` 또는 `get_document_node(path=..., depth=..., child_limit=...)`로 좁힌다. 구조·위치·서식 전체가 실제로 필요한 작업에만 `detail="full"`을 명시한다. 문안 대조에 필요한 본문은 완전하게 읽으며, 미리보기 잘림을 내용 누락 검사 통과로 취급하지 않는다.

같은 문서 revision의 저장된 분석 결과를 재사용한다. 편집 후에는 변경된 revision과 관련 부분을 다시 확인한다. 도구 결과는 `structuredContent`를 우선 읽고 없을 때만 text JSON을 해석한다. 같은 결과의 두 표현이나 전체 문서맵을 모두 출력하지 않는다. 원문은 해당 job 안에 두고 모델에는 필요한 경로·좌표·값·개수만 전달한다. 병합 표의 전체 지도는 논리 격자마다 셀을 중복 표현할 수 있고 `get_table_text`는 실제 셀만 반환하므로, 개수만 비교하지 말고 실제 셀 주소에 맞춰 내용과 공란을 대조한다.

## 로컬 읽기

선택 파일의 요청을 하나의 JSON 배열로 작업 폴더에 저장한다. 도구 인자는 설치된 HWPX 계약을 따르며 여러 읽기를 한 연결로 처리한다.

```json
[{"tool":"get_document_text","arguments":{"filename":"D:/path/selected.hwpx"}}]
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Invoke-HwpxRead.ps1 -RequestPath <requests.json> -OutputPath <new-results.json>
```

이 실행기는 현재 하네스에 등록된 서버·패키지와 설정된 접근 루트를 사용한다. 출력은 원문을 포함할 수 있으므로 해당 작업 안에 보관하고 기존 결과를 덮어쓰지 않는다. 필요한 본문·표·각주 등이 포함됐는지 확인한다. 오류/timeout은 성공이 아니며, 원인이 바뀌기 전 같은 요청을 반복하지 않는다.

## 편집과 종료

MCP 연결 시 설치된 스킬의 해당 workflow를 사용한다. 위 경로 선택에 따라 로컬로 처리할 때 지원 edit-plan은 `Invoke-HwpxEditPlan.ps1`, 동일 양식 명단은 [collection workflow](../collect-hwpx-rosters/SKILL.md)를 사용한다. 원본 해시·dry-run·검증 영수증·게시 계약을 유지한다.

로컬 edit-plan은 step과 중첩 연산의 이름을 구분한다. 문단 내용만 바꾸는 예는 `{"op":"paragraph_patch","args":{"patches":[{"paragraph_index":0,"text":"변경문"}]}}` 또는 `{"op":"apply_body_ops","args":{"ops":[{"op":"set_paragraph_text","index":0,"text":"변경문"}]}}`이다. `paragraph_patch`를 `apply_body_ops.args.ops` 안에 넣지 않는다. scope 거부가 나면 먼저 계획의 연산·인자 구조를 확인하며 내용 수정 때문에 서식 권한을 넓히지 않는다.

한 계획의 단계는 순서대로 적용된다. 셀 채움 등이 문단 수·순서를 바꾸면 뒤 단계에 원본의 문단 인덱스를 그대로 쓰지 않는다. 원본 좌표에 의존하는 독립 문단 편집을 먼저 수행하거나, 중간 저장본을 다시 읽어 후속 좌표를 정한다. 두 방식 모두 대상 겹침·덮어쓰기를 확인하고 저장본 내용 검사로 최종값을 대조한다.

내용검증 필수 job에서 문단을 편집할 때는 `-ParagraphTargetsPath <job 내부 JSON>`도 전달한다. 계약은 `{"source_sha256":"원본 SHA256","targets":[{"section_path":"Contents/section0.xml","paragraph_index":0,"before":"수정하려는 기존 원문"}]}`이다. 설치 런타임의 Python으로 `.agent/shared/paragraph_target_preflight.py --inspect <보존 사본> --operation paragraph_patch --output <새 내부 JSON>`을 실행하면 실제 편집기의 좌표 후보를 읽는다. `set_paragraph_text`를 쓸 때는 해당 operation을 지정한다. 두 편집기의 번호와 내용검사기의 XML 문단 번호는 서로 다를 수 있다. 후보 중 의도한 원문·문맥을 확인한 항목만 계약에 넣으며, 성공시키려고 다른 문장의 before를 복사하지 않는다. 실행기는 누락·중복·해시 변경·원문 불일치·선행 변이·혼합 좌표계를 거부한다. 표를 포함한 상위 문단은 통째로 교체하지 않고 셀이나 안전한 하위 문단으로 나눈다.

읽기 실행기로 쓰기 도구를 우회 호출하거나 ZIP/XML을 직접 편집하지 않는다. 기존 로컬 실행기가 지원하지 않는 전문 편집은 그 부분의 제한을 보고하고 독립 작업을 계속한다.

읽기는 필요한 내용 확인으로, 수정은 변경 범위와 파일 무결성 검사로 끝난다. 서식·시각 검수는 사용자 요청 또는 선택한 전문 작업의 필수 조건에 따른다.

런타임/연결 설정을 실제 설치·복구·갱신할 때만 [유지보수 절차](maintenance.md)를 읽는다. 문서 작업의 자동 대체 경로가 아니다.
