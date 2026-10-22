# 기존 ODT 초안/양식 채우기

모든 문서는 사용자가 지정한 기존 초안/양식을 실제 읽고 그 구조에 내용을 채운다. 지정 파일이 없으면 반드시 멈춰 사용자에게 질문한다. 내용의 근거 자료만 있고 초안/양식이 없을 때도 같다. 빈 ODT부터 새 양식을 만들거나 배포 자산을 자동 선택하지 않는다. 문서의 원래 형식을 따르며 기존 HWPX/HWP/DOCX를 자동으로 ODT로 바꾸지 않는다. 다른 형식이 필요하면 사용자가 선택하도록 질문한다.

## 지원 범위와 선택

`draft_odt.py`는 **사용자가 명시적으로 선택한 기존 `.odt`**를 `--template`으로 받아 지원되는 자리표시자 범위만 채운다. 제목 `{{TITLE}}`과 본문 `{{BODY}}`가 독립된 문단에 있어야 하며, 본문 자리표시자는 정확히 하나여야 한다. 그 밖의 선택 자리표시자는 `{{AGENCY}}`, `{{RECIPIENT}}`, `{{VIA}}`, `{{SENDER}}`이다. 알 수 없는 표식, 고정 문구와 섞인 표식, 일반 현재본에는 이 제한된 도구를 사용하지 않는다. 이 경우 `needs_input`으로 멈추고 기존 문서의 수정 위치와 구조를 보존하는 편집 경로를 확인한다. 새 양식으로 재생성하지 않는다.

`assets/general.odt`와 `assets/internal.odt`는 빈 예제 파일이다. 사용자가 그 실제 파일을 지정했을 때만 기존 양식으로 사용할 수 있다. `--form general/internal`은 호환용 분류 이름일 뿐 자산을 선택하지 않으며 `--template`을 대신하지 않는다. `--form paste`와 자동 빈 문서 생성 경로는 업무 CLI에 없다. 예제 자산의 글꼴·A4 여백은 그 파일의 속성일 뿐 다른 현재본의 기본값이 아니다. 자산의 해시와 개인정보 검사 기록은 [출처 기록](template-provenance.json)에 있다.

먼저 기준 파일의 제목·본문·표·붙임·결재 범위와 내용이 실제 읽혔는지 확인한다. 관련 문서나 과거 업무 파일은 근거 자료일 수 있지만 사용자가 지정한 초안/양식을 대신하지 않는다. 지원되지 않는 구조를 평탄화하거나 버리지 않는다.

## 실행

아래 설치 기록과 고정 의존성 요구는 `run_odt.py`/`draft_odt.py` 경로에 해당한다. 일반 ODT의 정확한 문구 교체는 아래 [보존 편집](#일반-odt의-보존-편집) 경로를 사용한다.

현재 하네스의 `.agent/index/odt-runtime.json`에서 `pythonPath`와 `dependencyDirectory`를 읽는다. 기록이나 실제 실행기·의존성이 없으면 [INSTALL](../../../../INSTALL.md)의 선택 ODT 설치를 따른다. 전역 Python 별칭이나 예전 설치 컴퓨터의 절대경로를 추정하지 않는다. 설치 기록은 배포 ZIP에 포함되지 않는다. `run_odt.py`는 `--deps`로 받은 고정 의존성의 버전과 실제 import 위치를 검사하며 자동 설치하지 않는다.

`<선택한 기존양식>`은 사용자가 지정한 실제 기존 `.odt` 파일로 바꾼다. 생성기가 양식을 골라 채우도록 이 인수를 생략하지 않는다.

```powershell
$odtRuntime = Get-Content -LiteralPath '.agent/index/odt-runtime.json' -Raw -Encoding UTF8 | ConvertFrom-Json
& $odtRuntime.pythonPath '.agent/shared/official-odt-draft/scripts/run_odt.py' --deps $odtRuntime.dependencyDirectory --runtime-check
& $odtRuntime.pythonPath '.agent/shared/official-odt-draft/scripts/run_odt.py' --deps $odtRuntime.dependencyDirectory --template '<선택한 기존양식>.odt' --data '<선택job>/draft.json' --output '<선택job>/draft.odt'
& $odtRuntime.pythonPath '.agent/shared/official-odt-draft/scripts/run_odt.py' --deps $odtRuntime.dependencyDirectory --check '<선택job>/draft.odt'
```

`--template`이 없으면 입력 JSON을 읽거나 출력 파일을 만들기 전에 종료 코드 2와 `status: needs_input` 및 기존 양식 요청 메시지를 반환한다. 지정 파일이 실제 ODT가 아니거나 지원되는 자리표시자가 없어도 출력 생성 전에 중단한다. 원본과 이미 있는 출력 파일을 덮어쓰지 않는다. 후속 수정은 정확한 현재본을 읽고 요청 범위만 편집한다.

## 일반 ODT의 보존 편집

`scripts/edit_existing_odt.py`는 선택한 기존 `.odt`의 `content.xml`에서 명시 주소의 leaf `text:p`/`text:h` 또는 leaf `text:span` 내부 텍스트만 교체한다. XML을 다시 직렬화하지 않고 선택한 텍스트 바이트만 바꾸므로 나머지 XML, 스타일, 필드, 그림과 패키지 멤버 내용·순서를 보존한다. ZIP은 다시 압축하므로 압축 바이트·플래그 전체의 동일성은 보장하지 않는다. 원본과 기존 출력 파일은 덮어쓰지 않으며 후보를 재열어 검사한 뒤 같은 폴더에 원자적으로 게시한다.

이 실행기는 Python 표준 라이브러리만 사용한다. `odt-runtime.json`의 유효한 `pythonPath` 또는 Codex의 `load_workspace_dependencies`로 확인한 번들 Python 경로를 `$odtPython`에 지정한다. 기록이 없다는 이유로 이 경로에서 설치를 요구하거나 전역 Python 별칭을 추정하지 않는다.

필수 XML·ODF 본문·스타일 루트·manifest 참조·CRC를 검사한다. 기존 파일의 mimetype 위치/압축 방식이 일반 ODT 패키지 규칙과 달라도 원래 배열을 보존하며 영수증 `source_mimetype_conventional:false`로 밝힌다. 이 경우 규격 적합성이나 기안기 호환성을 확인했다고 보고하지 않는다.

```powershell
& $odtPython '.agent/shared/official-odt-draft/scripts/edit_existing_odt.py' --source '<선택한 현재본>.odt' --inspect
& $odtPython '.agent/shared/official-odt-draft/scripts/edit_existing_odt.py' --source '<선택한 현재본>.odt' --plan '<선택job>/edits.json' --output '<선택job>/candidate.odt' --receipt '<선택job>/dry-run.json' --dry-run
& $odtPython '.agent/shared/official-odt-draft/scripts/edit_existing_odt.py' --source '<선택한 현재본>.odt' --plan '<선택job>/edits.json' --output '<선택job>/candidate.odt' --receipt '<선택job>/dry-run.json' --apply
```

계획 JSON은 `{"source_sha256":"inspect의 해시","edits":[{"node":2,"before":"기존 문구","after":"확인된 새 문구"}]}` 형식이다. `paragraph`는 문단·제목만 센 0 기반 주소이며 `node`는 문단·제목·span을 문서 순서로 센 별도 0 기반 주소다. `--inspect`의 주소와 `editable:true`를 그대로 선택하고 두 주소를 한 편집에 섞지 않는다. 문구 검색만으로 대상 위치를 추정하지 않는다. 동일 문구가 여러 곳에 있어도 주소와 원본 해시로 정확한 대상을 선택한다. 편집 불가 항목의 `text`는 직접 텍스트만 표시하므로 문서 전체 읽기를 대신하지 않는다.

`--inspect`의 각 항목에는 읽기 전용 `context.paragraph`와 `context.cells`가 함께 표시되며, 이는 내용 검증기의 0 기반 문단·표/행/열 locator와 일치하고 중첩 표의 조상 셀 및 반복 행·셀의 모든 논리 좌표를 포함하되 표당 10,000개 좌표 초과·잘못된 반복 수·미지원 행 구조에서는 `cell_context_status: unsupported`로 명시하므로 의미에 맞는 수정 위치는 문서와 대조해 선택한다.

비슷한 이름의 항목이 여러 위치에 있으면 각 라벨과 인접 값칸을 함께 읽어 용도를 구분한다. 초안에서는 편집 계획의 대상 주소를 재사용하여 저장본의 핵심값과 인접 라벨을 확인한다. 별도 내용 계약은 명시적으로 엄격검증을 요청한 경우에만 만들며, 그때 값칸과 보존할 라벨을 함께 기록한다.

원본 SHA256, 정확한 before, 중복 주소·다른 주소로 같은 범위 선택, dry-run의 계획·출력 경로 일치를 검사한다. dry-run은 ODT를 생성하지 않고 새 영수증만 저장하며 기존 영수증도 덮어쓰지 않는다. 계획을 바꾸면 새 영수증으로 dry-run을 다시 한다. 영수증은 검증 기록이며 사용자 승인이나 내용의 사실 확인을 대신하지 않는다.

복합 문단 전체는 평탄화하지 않는다. `node` 전체 교체는 leaf span에만 가능하다. bookmark·text:s·탭·중첩 span이 섞인 문단은 `--inspect`의 `segments`에서 직접 텍스트 조각을 선택하고 `{"segment":12,"before":"기존 문구","after":"새 문구"}`로 지정한다. segment는 문단/제목/span 안의 연속된 XML 문자 데이터(text 또는 자식 뒤 tail)를 센 별도 0 기반 주소이며 함께 표시되는 `node`는 상위 문단/span 주소다. 필드·공백 요소·bookmark 자체는 바꾸지 않고 해당 텍스트 바이트만 바꾼다. 서로 다른 주소 방식으로 겹치는 범위를 선택하면 거부한다. segment의 기존 앞뒤 일반 공백은 개수를 그대로 유지할 때 허용한다. `after:""`로 옛 시행번호·직책 등의 글자만 비울 수 있으며 둘러싼 요소와 누름틀은 보존한다. 같은 계획의 모든 주소는 편집 전 원본을 기준으로 하고, 저장 후 추가 편집은 다시 inspect한다. 내부 반복 공백 추가, 새 줄바꿈, CDATA 내용 변경은 지원하지 않는다.

빈 self-closing 요소, UTF-8 이외 XML, 서명·암호화·중복 ZIP 멤버도 거부한다. 문단 추가·표 구조 변경·HWPX 편집에는 사용하지 않는다. 실제 화면·줄 넘침·기안기 호환성은 이 파일 검사로 확인되지 않는다.

표준 라이브러리 회귀 검사는 같은 Python으로 `-B -m unittest discover -s .agent/shared/official-odt-draft/scripts -p test_edit_existing_odt.py -v`를 실행한다. 합성 자료는 시스템 TEMP에만 만든다.

## 자리표시자 내용 입력

JSON 예(가상 내용):

```json
{
  "title": "회의 개최 계획",
  "agency": "예시고등학교",
  "recipient": "내부결재",
  "related": [{"agency": "예시고등학교", "number": null, "date": [null, null, null]}],
  "body": [
    "2. 다음과 같이 회의를 개최하고자 합니다.",
    "  가. 일시: 0000. 0. 0. 00:00",
    "  나. 장소: 00",
    "  다. 안건: 00"
  ],
  "attachments": []
}
```

- 제목과 본문은 필수다. `body`는 문단별 문자열이며 목적에 맞는 번호를 작성자가 넣는다. 관련 항목과 본문 번호의 연속성을 대조한다. 마지막 `끝.`은 도우미가 추가하므로 입력 본문에 중복하지 않는다. 사실관계·날짜를 임의로 고치지 않는다.
- `related` 생략은 미확인 공문 한 건이며 관련이 없다는 것이 확인됐으면 `[]`이다. 법령·지침명은 `[{"basis":"확인된 근거명"}]`을 쓴다. 번호와 날짜가 같은 문서의 것인지 확인한다.
- 날짜는 `"2026-09-04"`, `"2026. 9. 4."`, `[2026,9,4]`를 받으며 결과는 `2026. 9. 4.`다. 일부 미확인은 `[2026,9,null]` → `2026. 9. 0.`, 모두 미확인은 `0000. 0. 0.`이다.
- `attachments`는 `[{"name":"실제 자료명","quantity":"1부"}]` 형식이다. 예정 목록과 실제 첨부 완료를 구별한다. 이 도구는 파일을 실제 첨부하지 않는다.
- 일반 양식의 기관·수신이 누락되면 미확인 표시, 경유·발신명의는 빈칸이다. 내부결재의 발신명의를 임의로 추가하지 않는다. 기존 문서의 고정 문구나 작성자 자기소개를 새로 덧붙이지 않는다.
- 기존 표가 있거나 새 표를 해당 양식에 채워야 한다면 구조를 지원하는 편집 경로를 선택한다. 이 JSON 도구는 일반 문단과 붙임 목록만 지원하며 표·병합·그림을 재생성하거나 긴 텍스트로 바꾸지 않는다.

## 서식과 패키지 보존

기본 호출은 기준 문서의 글꼴·크기·줄간격·여백·기존 스타일·표·등록/결재란을 유지한다. 본문은 `{{BODY}}` 문단을 복제해 그 문단 스타일을 상속한다. 단일 글꼴 정리, 전체 스타일 재작성, 번호 폭 기반 내어쓰기 재계산, 메타데이터 제거를 수행하지 않는다. 기존 번호 들여쓰기나 붙임 구조에 맞지 않는 경우 지원 편집 경로를 확인하며 새로운 기본 양식으로 대체하지 않는다.

사용자가 서식 변경을 명시한 경우에만 `typography`에 요청한 `font_name`, `size`, `line_height`를 넣는다. `line_height`는 `160%` 같은 양의 백분율 문자열이며 입력한 속성만 제목/기관 등 교체된 자리표시자 문단과 본문에 적용한다. 대상 문단과 span의 스타일을 복제하므로 고정 문구·결재란과 원래 스타일 정의는 변하지 않는다. `font_file`은 `font_name`과 함께 전달할 수 있지만 현재 도구는 글꼴 폭을 계산하지 않는다. 글꼴 표시와 실제 기안기 호환성은 별도 확인한다.

ODF 문서 API로 선택 범위를 채운 후 변경된 `content.xml`만 출력에 반영한다. `styles.xml`, `meta.xml`, `settings.xml`, 이미지, manifest 등 다른 ZIP 멤버는 기준 파일의 바이트와 멤버 정보를 그대로 복사한다. 기준 파일 경로와 SHA-256을 완료 정보에 남기며 작업 중 기준 파일이 달라지면 멈춘다. 원본 파일은 수정하지 않는다.

## 완료 확인과 한계

MIME·ZIP·XML·manifest, odfpy 재열기, 제목과 본문 문단의 왕복 일치, 결재 필드 목록 보존, 남은 기계용 표식을 검사한다. `--check` 단독 실행은 패키지 검사만 수행하며 서식 전체 검사나 내용 정확성 검사 완료를 뜻하지 않는다. 문서번호·날짜·회차·대상·수량·붙임 목록·요청 범위는 작성자가 근거와 대조한다. 저장된 구조 보존을 실제 화면·줄바꿈·기안기 읽어오기 완료로 보고하지 않는다.

유지보수용 `run_odt.py --self-test`는 합성 기준 파일에서 양식 미지정 중단, 일반 현재본 재생성 거부, 원본/출력 덮어쓰기 방지, 기존 패키지와 고정 문구/스타일 보존, 선택 범위 서식 변경을 검증한다. 테스트는 사용자 문서를 변경하지 않는다.

`paste_odt.py`, `basic_format.py`, `body_table.py`, `font_profile.py`의 신규 문서/표 생성 기능은 유지보수와 과거 호환성 연구를 위한 부속 도우미다. 기존 양식이 없을 때 호출하는 업무 대체 경로가 아니다. [포털 참고](portal-paste.md)의 붙여넣기 실험 설명도 이 원칙을 바꾸지 않는다.
