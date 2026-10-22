# 저장본 내용 계약

이 문서는 명시적으로 전항목 대조·필수 프로필 검증을 요청한 HWPX·ODT 작업의 선택 경로다. 해당 접수에 `Start-HwpxWork.ps1 -RequireContentValidation`을 사용하며 같은 요청 재시도에서는 요구가 유지된다. 일반 초안은 [초안 우선 경로](SKILL.md#근거를-연결하고-초안-저장)를 사용하고 이 계약을 만들지 않는다. 값 확인만 하거나 기존 파일을 읽기만 할 때는 접수·계약·게시를 만들지 않는다. DOCX·XLSX 등 다른 출력 형식과 이를 포함한 혼합 산출물 집합에는 이 게이트가 미지원이며 기존 형식별 검증을 유지하고 그 제한을 보고한다.

모델은 근거·항목 대응, 충돌 해결, 수정 범위를 판단한다. 직접 사실은 `sourceRef`, 계산은 원본 위치를 사용하는 `expectedExpr`로 검증해 작성자가 적은 기대값과 결과가 함께 틀리는 것을 방지한다. 도구는 저장된 문서의 실제 값·출처 해시·출력 바인딩을 검사한다. 문서마다 최소 한 검사는 기술적 하한이며 내용 완전성의 증명은 아니다. 요청 항목 전체, 반복된 명단·요약·동의서, 근거 없는 연락처의 공란, 확인한 예시·옛 날짜·삭제 안내를 각각 포함한다. 실패는 해당 내용을 고치거나 미확정 상태로 보고하며 검사 삭제·확정 근거 변경·새 요청 접수로 우회하지 않는다.

산출식은 총액만 검사하지 않고 단가·수량·인원·횟수·기간의 역할과 단위를 함께 대조한다. 같은 곱셈 결과라도 수량을 횟수로 바꾸면 다른 계획이다. 단위를 확인할 수 없으면 임의로 붙이지 않고 근거에 적힌 구분을 유지한다.

병합 표의 항목은 라벨과 값 입력칸을 구분해 계약에 기록한다. 값이 문서 어딘가에 존재하는지만 보지 않고 지정 입력칸의 값을 검사하며, 인접 라벨은 기준본과 동일한지 별도로 검사한다. 기준본을 sources에 등록하고 `sourceRef:{source:"form",locator:{kind:"cell",section:0,table:0,row:0,col:0}}`로 원래 라벨을 직접 참조할 수 있다. 출력 위치와 원본 위치는 각각 읽어 확정하며 같은 좌표라고 추정하지 않는다.

문서형 sourceRef는 source와 locator만 지정한다. HWPX 셀·문단은 section을 포함하고 ODT는 section을 넣지 않는다. 좌표는 0 이상의 정수이며, 존재하지 않거나 여러 번 일치하는 위치는 실패한다. 공란인 원본을 기대값으로 자동 채택하지 않으며 공란 보존이 맞는 항목은 별도 blank 검사로 명시한다.

1. 선택한 기존 기준본과 근거를 읽고 변경 항목을 확정한다.
2. 같은 job의 `content-contract.json`에 출처·산출물·검사 항목을 기록한다. `--inspect <HWPX/ODT> --inspect-output <내부 JSON>`으로 실제 문단·셀 좌표를 읽을 수 있다.
3. 지원 편집 도구로 저장한 후 기존 Python으로 `validate_content_contract.py --job <job>`을 실행한다. 실행기는 `.agent/shared/`에 있다. 성공 시 `wip/receipts/content-validation.json`을 만든다. 실패한 검사 ID에 해당하는 내용만 수정하고 재검사한다.
4. 해당 형식의 무결성 검사도 마친 뒤 일반 완료·게시 경로를 쓴다. 필수 검사 job의 `Complete-HumanDraft.ps1`와 `Publish-HumanResult.ps1`은 영수증 존재만 믿지 않고 계약·현재 출처·출력 내용을 재대조한다. 계약·출처·출력·완료 후 영수증이 달라졌으면 다시 검증·완료한다.

```json
{
  "schemaVersion": "content-contract/v1",
  "sources": [{"id": "roster", "path": "C:/selected/roster.xlsx", "sha256": "64자리 실제 SHA256"}],
  "outputs": [{"id": "application", "path": "wip/docs/application.hwpx", "targetRelativePath": "신청서.hwpx"}],
  "assertions": [
    {"id": "student-name", "output": "application", "locator": {"kind": "cell", "section": 0, "table": 0, "row": 1, "col": 0}, "op": "exact", "sourceRef": {"source": "roster", "sheet": "명단", "cell": "B2"}},
    {"id": "unknown-phone", "output": "application", "locator": {"kind": "cell", "section": 0, "table": 0, "row": 1, "col": 1}, "op": "blank", "normalize": ["trim"]},
    {"id": "old-placeholder", "output": "application", "locator": {"kind": "cell", "section": 0, "table": 0, "row": 2, "col": 0}, "op": "absent", "expected": "예시 성명"}
  ]
}
```

- 모든 ID는 해당 배열 안에서 고유해야 한다. 유효한 필수 프로필이 없는 빈 assertions, 빠진 산출물·파일, 중복 출력 경로, 0건/복수 좌표 매치, 불일치는 실패한다. 산출물은 같은 job의 `wip/docs` 또는 `wip/carry` 파일이며 모든 완료·게시 파일과 경로·해시가 일치해야 한다.
- HWPX 셀 좌표는 `{kind:"cell",section:0,table:0,row:0,col:0}`, 문단은 `{kind:"paragraph",section:0,index:0}`이다. 모든 번호는 0부터 시작하며 `table`은 해당 section의 XML 순서, row/col은 셀의 실제 주소다. ODT는 section을 생략한다. ODT 표/문단은 문서 XML 순서이며 반복 셀·행도 좌표로 펼친다. `--inspect`의 정확한 locator를 내용 검사에 재사용한다. 이는 검증기 좌표이며 편집 실행기의 문단·node·segment 번호와 같다고 가정하지 않는다. 편집 위치는 해당 편집 도구의 읽기 결과에서 원문과 대조해 별도로 정한다. 존재하지 않는 병합 하위 셀을 빈 셀로 가정하지 않는다.
- `kind:"document"`는 전체 텍스트 검사 범위다. 규정/참고자료에 같은 단어가 있으면 구체 셀·문단으로 제한한다. 연락처에도 쓰이는 `0000`이나 정상 일정에도 나오는 월 표시를 문서 전체에서 금지하지 않는다. 예시가 있던 셀·문단의 변경값을 검사한다. 전체문서 contains만으로 반복 위치의 채움을 대신하지 않는다.
- `exact`, `contains`, `absent`에는 `sourceRef`, `expectedExpr`, 문자열 `expected` 중 하나만 쓴다. `sourceRef`는 XLSX의 지정 sheet/cell 또는 HWPX·ODT의 지정 locator에서 기대값을 직접 읽는다. 두 형식의 지정자를 섞지 않는다. XLSX 공란·오류·수식 셀은 거부한다. 계산값은 아래 선언식으로 원본 값에서 계산하고 날짜도 원본을 변환한다. 자유 서술·확정 사용자 지시처럼 직접 산출할 수 없는 기대 문구만 `expected`에 쓰고 `evidence:[{source:"roster",location:"실제 시트·셀 또는 문서 위치"}]` 또는 `reason`을 기록한다. 이 자유 문구 근거 자체의 정확성은 검증기가 보장하지 않는다. 예시 잔존 absent는 불필요한 근거를 요구하지 않는다. blank는 expected/sourceRef/expectedExpr 없이 쓴다.
- 기본 비교는 원문 그대로다. `normalize`는 필요할 때만 `trim`(양끝 공백), `line_endings`(CR/LF 통일), `collapse_whitespace`(연속 공백 하나), `number`, `date`를 명시한다. `number`는 숫자 하나의 천단위 쉼표와 소수점 표기, 선택적 원/%/명/시간/개 접미어를 정규화한다. `25%`는 `25`이며 원본 `0.25`와 비교하려면 원본에 100을 곱한다. 여러 숫자가 섞인 산식·문장이나 잘못된 쉼표는 거부한다. `date`는 `2026. 4. 17.`, `2026-04-17`, `2026년 4월 17일` 같은 완전한 날짜를 ISO 날짜로 비교한다. 임의 수치·단위 환산이나 문장 의미를 자동 동치 처리하지 않는다.
- 출처 파일마다 실제 SHA256을 넣는다. 같은 sourceRef를 여러 위치 검사에서 재사용할 수 있다. 영수증에는 계약/출처/출력 해시와 검사 결과를 저장하며 불일치 항목은 로컬 영수증에 actual/expected를 기록한다. 이 값은 사람 정보가 있을 수 있으므로 공통 색인·채팅에 원문 전체를 복제하지 않는다. 성공은 시각·쪽배치·한컴 재열기 검사나 공식 결재·제출 완료를 뜻하지 않는다. 파일 구조상 텍스트만 읽으며 문서를 변경하지 않는다.

## 원본에서 계산하는 기대값

`expectedExpr`는 실행 코드가 아닌 제한된 선언식이다. 합계·곱셈은 Decimal로 계산하며 XLSX 수식의 캐시값을 정답으로 읽지 않는다. 각 인수는 아래 표현식 또는 그 중첩이다.

| 표현식 | 의미 |
|---|---|
| `{"sourceRef":{"source":"budget","sheet":"견적","cell":"E6"}}` | 해시가 확인된 원본 위치 읽기 |
| `{"literal":"1000"}` | 명시적 상수. 단위 환산 등의 근거를 프로필에 기록 |
| `{"outputRef":{"output":"application","locator":{"kind":"cell","section":0,"table":0,"row":1,"col":2}}}` | 저장된 출력 위치 읽기. 소계 합계 등 내부 모순 대조용 |
| `{"op":"sum","args":[표현식,표현식]}` | 1~1000개 인수 합계 |
| `{"op":"product","args":[표현식,표현식]}` | 1~1000개 인수 곱셈 |
| `{"op":"extract","arg":표현식,"pattern":"최종 (\\d+)명","group":1}` | 정확히 한 번 일치한 원본 메모에서 값 추출 |
| `{"op":"excel_date","arg":표현식}` | Excel 1900 날짜 체계의 정수 일련번호를 YYYY-MM-DD로 변환. 1900-03-01 이후 지원 |

표시 문자열에서 금액만 읽어야 하면 assertion에 `actualExtract:{"pattern":"[￦₩]([0-9,]+)","group":1}`를 추가한다. 추출은 `normalize` 전에 실행되고 0건·복수 일치·빈 그룹은 실패한다. 표에 금액이 단독으로 있으면 추출하지 말고 `normalize:["number"]`로 직접 비교한다.

```json
{
  "id": "line-cost",
  "output": "application",
  "locator": {"kind":"cell","section":0,"table":0,"row":1,"col":4},
  "op": "exact",
  "normalize": ["number"],
  "expectedExpr": {
    "op": "product",
    "args": [
      {"sourceRef":{"source":"budget","sheet":"견적","cell":"E6"}},
      {"sourceRef":{"source":"budget","sheet":"견적","cell":"G6"}},
      {"literal":"1000"}
    ]
  }
}
```

총액의 기대값을 출력의 소계만으로 계산하면 두 값이 함께 틀릴 수 있다. 원본 항목별 산식·소계·총액 검사를 먼저 두고 `outputRef` 교차검사는 추가로 둔다. 단가·수량·횟수 각 칸도 별도로 검사한다. 메모에서 정정값을 추출할 때는 동일 ID와 날짜 우선순위를 먼저 확인한다.

## 업무별 필수 검증 프로필

반복 양식의 누락 방지 규칙은 업무폴더의 별도 `content-required-profile/v1` 파일에 둔다. 실제 원본 위치·양식 입력 지도·기준일·필수 항목·고정 라벨은 해당 업무 데이터이며 공통 검증 코드에 학교명이나 정답으로 하드코딩하지 않는다. 프로필 작성자는 원본과 양식을 먼저 대조하고, 바뀐 근거에 맞는 새 프로필은 명시적으로 검토해 새 요청에 연결한다.

`Start-HwpxWork.ps1 -ContentProfilePath <프로필 절대경로>`로 선택하면 접수 시 `inputs.json`의 `requiredContentProfile:{path,sha256}`가 고정된다. 계약의 `requiredProfile`에는 이 객체를 그대로 넣는다. 출처 ID는 프로필의 `sourceHashes` 키, 출력 ID는 `requiredOutputs`에 맞춘다. 프로필은 다음 구조다.

```json
{
  "schemaVersion": "content-required-profile/v1",
  "sourceHashes": {"roster":"64자리 실제 SHA256", "form":"64자리 실제 SHA256"},
  "requiredOutputs": ["application"],
  "assertions": [
    {"id":"required-name","output":"application","locator":{"kind":"cell","section":0,"table":0,"row":1,"col":1},"op":"exact","sourceRef":{"source":"roster","sheet":"명단","cell":"B2"}},
    {"id":"fixed-label","output":"application","locator":{"kind":"cell","section":0,"table":0,"row":1,"col":0},"op":"exact","sourceRef":{"source":"form","locator":{"kind":"cell","section":0,"table":0,"row":1,"col":0}}}
  ]
}
```

검증기는 프로필 해시·필수 출처 해시·출력 ID를 확인하고 필수 assertions를 직접 합친다. 그러므로 계약의 `assertions:[]`도 필수 프로필이 유효하면 허용되며, 빠진 필수 검사가 사라지는 것이 아니다. 같은 ID로 다른 검사 내용을 덮어쓰면 실패한다. 프로필 참조 누락·교체·파일 변조·필수 출처 누락·필수 출력 누락은 실패한다. 프로필이 연결되지 않은 일반 v1 계약은 기존 동작을 유지한다.

필수 프로필은 모델이 문서를 작성한 뒤 그 결과에 맞춰 축소하는 자체 채점표가 아니다. 실패를 없애기 위해 검사·프로필·접수 바인딩을 삭제하거나 기대값을 결과에 맞추지 않는다. 원본 자체가 바뀌었거나 프로필의 원본 대응이 잘못된 경우에는 그 차이를 보고하고 프로필을 검토한 후 다시 접수한다. 프로필이 있어도 자유 서술의 의미와 실제 페이지 외관은 별도로 검토한다.
