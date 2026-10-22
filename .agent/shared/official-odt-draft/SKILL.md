---
name: official-odt-draft
description: 학교 공문·기안문의 기존 기준본에 근거 내용을 채운다. 일반 ODT의 문구·표 값 보존 편집과 공문 고유의 수신·관련·붙임 확인에 사용한다.
---

# 공문 초안 채우기

기준본 선택·원본 보존·출력 위치는 작업공간 AGENTS를 따른다. 원래 형식으로 편집하며 HWPX/HWP/DOCX를 ODT로 자동 변환하지 않는다. 이 스킬의 ODT 도구는 선택된 기존 ODT에만 쓴다. 배포 빈 자산은 사용자가 그 파일을 선택한 경우에만 기준본이다.

## 내용 결정

기준본의 본문·붙임·결재 범위를 읽고 현재 근거로 요청한 부분을 채운다. 이미 확정한 선택은 재사용한다. 요청이 원문과 충돌해 중복 기안이나 다른 문서 종류를 만들게 되면 근거와 대안을 제시하고 그 선택만 질문한다. 선택과 무관한 작업은 계속한다.

- **수신:** 상단 수신란에 실제 수신 기관을 넣는다. 하단 수신자 배포목록으로 대신하지 않는다. 수신·경유·우·전화·전송 같은 고정 라벨은 값과 구별해 보존한다.
- **관련:** 문서번호와 날짜가 같은 원문의 것인지 확인한다. 파일명·회의일·첨부 작성일·파일 수정일로 추정하지 않는다. 미확인 부분만 `00고-0000(0000. 0. 0.)`처럼 남기며 확인된 값은 유지한다.
- **붙임:** 실제 제공·생성한 파일 또는 사용자가 명시한 예정 목록과 제목·수량을 맞춘다. 통합 파일 한 개를 여러 첨부 파일로 적지 않는다. 예정과 첨부 완료를 구분한다.
- **미확정 정보:** 자체 등록번호·결재일·서명·직인·공개 구분은 근거가 없으면 비운다. 옛 공문의 승인 사실을 복제하지 않는다. 신청을 승인 완료로 바꾸지 않는다.

작성자 자기소개·대화 인사말은 본문에 추가하지 않는다. 필수 사실이 일부 없어도 채울 수 있는 부분은 초안으로 저장한다. 날짜·항목 번호·붙임·끝 표기 등이 필요할 때 [공식 작성 기준](references/writing-guide.md)의 해당 부분을 확인한다. 공식 편람과 옛 관행이 충돌하면 수정 범위부터 확인한다.

## 일반 ODT: 읽기 → 편집 계획 → 저장

`edit_existing_odt.py`는 표준 라이브러리만 필요하다. `.agent/index/odt-runtime.json`의 유효한 `pythonPath` 또는 도구 `load_workspace_dependencies`로 확인한 번들 Python을 `$odtPython`에 지정한다. 설치 기록이 없다는 이유만으로 새 설치를 요구하지 않는다. 전역 Python 별칭·다른 PC 경로는 추정하지 않는다.

`$source`는 선택한 기준 ODT, `$jobPath`는 현재 작업 경로다. 아래 경로는 프로젝트 루트 기준이다.

```powershell
$editor='.agent/shared/official-odt-draft/scripts/edit_existing_odt.py'
$plan=Join-Path $jobPath 'wip/edits.json'
$receipt=Join-Path $jobPath 'wip/receipts/odt-dry-run.json'
$output=Join-Path $jobPath 'wip/docs/제출공문.odt'
& $odtPython -X utf8 -B $editor --source $source --inspect
```

inspect의 `source_sha256`, `nodes`의 주소·`editable:true`·정확한 `text`, `context.cells`를 읽고 값칸과 인접 라벨을 구별한다. 그 결과로 `$plan`에 UTF-8 JSON을 쓴다. 숫자 2와 문구는 예시이며 실제 inspect 결과로 바꾼다.

```json
{"source_sha256":"inspect에서 읽은 해시","edits":[{"node":2,"before":"기존 문구","after":"근거로 확인한 문구"}]}
```

```powershell
& $odtPython -X utf8 -B $editor --source $source --plan $plan --output $output --receipt $receipt --dry-run
& $odtPython -X utf8 -B $editor --source $source --plan $plan --output $output --receipt $receipt --apply
& $odtPython -X utf8 -B $editor --source $output --inspect
```

각 명령이 성공한 뒤 다음으로 진행한다. dry-run은 편집 검증 영수증만 만들며 사용자 승인이나 사실 확인을 대신하지 않는다. 원본·계획·출력 경로가 같아야 apply할 수 있다. 기존 출력과 영수증은 덮어쓰지 않으므로 수정 계획을 바꾸면 새 내부 파일명을 쓴다.

복합 문단은 평탄화하지 않는다. leaf node 대신 직접 텍스트 조각인 `segment`가 필요하거나 빈 셀·필드·구조 제한에 부딪히면 [보존 편집 상세](references/odt-workflow.md#일반-odt의-보존-편집)만 읽는다. 지원 자리표시자가 있는 양식을 채울 때도 같은 참조의 실행·입력 절을 사용한다.

## 초안 마무리

저장본의 실제 채운 제목·수신·관련·붙임과 고정 라벨을 한 번 확인한다. 도구의 패키지·재열기 검사 결과와 함께 실제 검사만 완료로 기록하고 [초안 저장 경로](../../../.agents/skills/hwpx-workspace-delivery/references/draft-quickstart.md)로 게시한다. 미확정 사항과 다음 보완 최대 3개를 채팅으로 알린다. 기본 초안에 전수검사·PDF·스크린샷·한컴 실행을 추가하지 않는다. 파일 검사를 실제 화면·줄바꿈·기안기 호환성 확인으로 보고하지 않는다.

서식 변경·새 본문 표·결재문서 읽어오기·호환성 문제·요청 충돌의 상세 처리는 [고급 절차](references/advanced-workflow.md)의 관련 절만 읽는다. 기존 양식을 전체 단일 글꼴로 정리하거나 유지보수용 빈 문서 생성기로 대체하지 않는다.
