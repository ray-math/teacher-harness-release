# 계획 저장·적용 형식

사용자의 자연어 업무 순서를 내부 계획 JSON으로 옮길 때 읽는다. 사용자가 JSON을 작성할 필요는 없다. 도구 경로는 작업공간 루트 기준이다.

이 내부 계획은 업무 순서·배치용이므로 문서 양식 요구의 대상이 아니다. 계획에서 문서·표·텍스트 산출물 작성으로 넘어가면 [기존 초안/양식 우선](../../hwpx-workspace-delivery/references/reference-scope.md#초안양식을-먼저-열기)을 먼저 적용한다. 산출물 기준본이 없거나 읽을 수 없거나 선택이 모호하면 해당 작성 단계는 멈추고 필요한 자료를 요청한다. 파일 목적지를 등록했다고 새 양식을 만들지는 않는다.

## 최소 계획

최상위는 실제 등록 업무명인 `taskTitle`과 비어 있지 않은 `steps`를 둔다. 새 단계는 아래 필드를 사용한다.

| 필드 | 작성 기준 |
|---|---|
| `id`, `title` | 의미 있는 고유 영문 ID와 짧은 제목. ID는 영문·숫자·`_`·`-`로 쓰며 같은 작업이면 유지한다. |
| `period` | 확인된 시기 또는 착수 조건. 근거가 없으면 `일정 확인 필요`. |
| `action` | 실제 할 일을 적은 비어 있지 않은 **문자열**. 여러 행동은 줄바꿈으로 구분한다. 배열·객체는 실행기가 받지 않는다. |
| `basis` | `user`: 사용자 지정 순서, `prior`: 이전 관행, `current`: 현재 근거. 사용자 지정은 공식 근거나 업무 완료 증거가 아니다. |
| `evidence`, `locator` | 검토한 요지와 대화·파일 내 위치. 개인정보를 요지에 옮기지 않는다. |
| `storage` | `folder`, `file`, `none` 중 선택. 아래 배치 기준을 따른다. |

`prior/current`에는 intake로 등록한 실제 `sourcePath`, `sourceSha256`도 필요하다. 선택한 원문을 읽고 해시를 확인한다. 출처가 바뀌면 재검토한다. `user`를 위해 가짜 파일·해시·설명 TXT를 만들지 않는다. `result`는 확인 가능한 완료 기준이 있을 때만 추가한다.

```json
{
  "taskTitle": "실제 등록 업무명",
  "steps": [{
    "id": "review-request",
    "title": "요청 사항 확인",
    "period": "일정 확인 필요",
    "action": "사용자가 지정한 대상과 처리 순서를 확인한다.",
    "basis": "user",
    "evidence": "사용자가 제공한 순서의 실제 요지",
    "locator": "실제 대화 또는 제공 파일 내 위치",
    "storage": {"kind": "none"}
  }]
}
```

## 배치와 적용

- 여러 자료·산출물은 `{"kind":"folder","name":"대상 확인"}`, 파일 하나는 `{"kind":"file","name":"결과 보고 기안.odt"}`, 산출물 없으면 `{"kind":"none"}`을 쓴다. `name`에는 번호·경로 구분자를 넣지 않는다.
- 실행기가 순서에 맞는 번호와 `relativePath`를 계산한다. 기존 ID·경로를 유지하며 중간 추가는 `01-01` 같은 삽입 번호를 쓴다. 필요한 경우 `number`를 명시한다. 경로 변경은 별도 이동 매핑과 등록·링크 갱신이 필요하다.
- `folder`는 필요한 폴더를 만들고 `file`은 목적지만 등록한다. 주요·상시 파일은 업무 루트 한 벌을 연결한다. 게시는 `Publish-HumanResult.ps1 -TargetRelativePath`에 실제 파일 목적지를 전달한다.
- 선택한 업무의 `jobPath` 안에 계획을 저장하고 `powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Prepare-WorkWorkflow.ps1 -JobPath <jobPath> -TaskTitle <등록명> -PlanPath <계획경로> -WorkFolder <선택폴더>`로 적용한다.
- 문서 작성 없이 순서·배치만 접수하는 `Start-HwpxWork.ps1` 호출에는 `-Purpose Workflow`를 사용한다. 이 job은 `Complete-HumanDraft.ps1`과 `Publish-HumanResult.ps1`로 문서를 완료·게시할 수 없다. 실제 문서 작성 요청에는 기본 `-Purpose Document`를 사용하고 초안/양식을 `-FormFile` 또는 `-HumanRevisionFile`로 지정한다. 등록된 현재본은 자동 확인하며 기준본 없는 `needs_input`은 사용자 자료 요청으로 해결한다.
- 이전 관행에서 빠진 단계를 도출할 때만 `-PlanPath` 없이 `-Keyword`, `-SeedFile`, 사용자가 지정한 `-PriorFolder`로 탐색한다. 후보 원문을 읽은 뒤 출처를 등록한다. 경로·해시가 같은 탐색 결과는 재사용하고 새 자료를 찾을 때 `-Refresh`를 쓴다. 기본 이전자료 경로나 보편적 학사 일정을 추정하지 않는다.

## 명시적 콘솔 요청에서만

`items: [{id,text}]`, `references: [{path,sha256}]`, `confirm`은 화면용 선택 항목이다. `items`를 쓰면 기존 체크 ID를 유지하고 `action`도 항목 문장을 줄바꿈으로 합친 문자열로 제공한다. `references`에는 실제 사용할 등록 출처만, `confirm`에는 구체적인 미확정 사항만 적는다. 체크는 결재·제출 완료 증거가 아니다.

콘솔 요청이 있을 때만 `-UpdateConsole`을 추가하며, 표시·직접 열기·보고는 [콘솔 보고](../../hwpx-workspace-delivery/references/console-report.md)을 따른다.

