# 일반 초안: 읽기 → 채우기 → 한 번 확인 → 게시

설치된 환경에서 기존 양식의 내용을 채우는 기본 경로다. 사용자에게 아래 옵션을 명령에 넣게 하지 않는다. 명령은 하네스 루트에서 PowerShell로 실행하고, JSON과 한글 스크립트는 UTF-8로 저장한다(Windows PowerShell 5.1 스크립트는 BOM 포함).

## 업무와 자료

같은 요청의 진행 중 job은 재사용한다. 새 업무는 다음처럼 접수한다. 파일 역할을 구분하면 잘못 등록했다가 다시 접수하는 일을 줄일 수 있다.

```powershell
$job = & .agent/shared/Start-HwpxWork.ps1 -Mode New -TaskTitle '<업무 제목>' -JobSlug '<영문-업무명>' `
  -RequestText '<실제 사용자 요청>' -IntakeSummary '<선택 자료와 작업>' -DecisionReason '<양식 선택 이유>' `
  -UserProvidedFile $selectedFiles -FormFile $forms -CurrentReferenceFile $evidence -AuthorityFile $officialRules `
  -DraftFirst -Summary | ConvertFrom-Json
```

`FormFile`: 사용자가 지정한 편집 기준본. `CurrentReferenceFile`: 올해 명단·예산·계획 등 채울 값의 근거. `AuthorityFile`: 공식 공고·규정. `ReferenceFile`: 이전 사례·참고 문서이며 현재 사실의 근거와 다르다. `UserProvidedFile`은 실제 사용할 자료만 전달하며 각 파일에 위 역할도 지정한다. 폴더의 실행 안내 TXT까지 무조건 접수하지 않는다. 없는 역할의 인수는 생략한다. 기존 문서 후속 수정은 `-Mode FollowUp -JobPath <기존 job>`과 등록된 현재본을 사용한다. 역할 변경·부분 파일 수정·기존 자동 보관 설정은 [접수 상세](artifacts.md)를 읽는다.

반환된 `jobPath` 아래 `wip`에 읽기 결과와 계획을, `wip/docs`에 작업본을 둔다. `inputs.json`에서 해당 원본 해시의 보존 사본을 사용한다. 같은 해시의 읽기 결과·성공 영수증은 재사용한다. 제공 원본을 편집하거나 실행 중 임의로 런타임을 설치하지 않는다.

## 한글 본문과 표

현재 `.agent/index/hwpx-runtime.json`의 `runtimeDirectory` 아래 `Scripts/python.exe`를 `$hwpxPython`으로 사용한다. 일반 HWPX는 다음 한 번의 읽기로 본문·표의 편집 좌표를 받는다. 페이지가 잘렸으면 `next_offset`부터 이어 읽고, 긴 셀의 `text_truncated` 표시가 있으면 필요한 범위의 `--max-text`를 늘린다. 미리보기만으로 내용을 다 읽었다고 판단하지 않는다.

```powershell
& $hwpxPython -X utf8 -B .agent/shared/inspect_hwpx_draft.py --source $basis --output "$($job.jobPath)/wip/inspection.json"
```

읽은 라벨·값칸으로 수정 위치를 정한다. 기본은 표 밖의 편집 가능한 `paragraph_patch` 문단과 표·셀만 반환해 중복을 줄인다. 다른 문단 연산이 필요하면 `--paragraph-operation set_paragraph_text`를 지정하며 좌표계를 섞지 않는다. 셀은 `table_index,row,col`을 사용하며 병합 칸을 중복 작성하지 않는다. `requires_full_read:true`인 셀이나 각주·그림·특수 구조까지 필요한 작업은 [한글 경로](hanword.md)의 전체 읽기 또는 전문 도구로 확인한다. HWP/HWTX 변환도 그 경로에 있다.

HWPX 양식은 기존 통합/분리 단위를 기록한다. 통합 양식의 신청서·계획서 등을 임의로 파일마다 분리하지 않는다. 아래 `$hwpxForms`는 접수에 등록한 기준 양식 경로다. 해당 양식의 내부 보존 사본을 `wip/docs/base/`에 복사해 원본 해시와 대조하고, 이를 편집 입력과 게시의 `$hwpxBases`로 사용한다. 기준 사본은 수정하지 않으며 결과는 별도 파일에 저장한다.

```powershell
& .agent/shared/New-HwpxFormContract.ps1 -FormStatus existing -AuthoritativeForm $hwpxForms `
  -FormLayout combined -ContainedSection '<실제 포함된 서식 이름들>' `
  -OutputPath "$($job.jobPath)/wip/receipts/hwpx-form-contract.json"
```

`combined`는 한 파일 안의 여러 서식, `separate`는 각각 별도 파일인 기준본이다. 복제 변형·병합은 [한글 경로](hanword.md)를 따른다.

편집 계획 예(실제로 읽은 위치·문구·해시로 바꾼다):

```json
{
  "schemaVersion": "hwpx.edit-plan/v1",
  "source": "<보존 사본>.hwpx",
  "output": "<job>/wip/docs/draft.hwpx",
  "steps": [
    {"id":"body","op":"apply_body_ops","args":{"ops":[
      {"op":"replace_text","find":"기존 문구","replace":"확인된 새 문구","count":1}
    ]}},
    {"id":"cells","op":"fill_cells","args":{"cells":[
      {"section_path":"Contents/section0.xml","table_index":0,"row":1,"col":2,"text":"확인된 값"}
    ]}}
  ]
}
```

같은 계획에 모아 dry-run 후 적용한다. 좌표는 section별이므로 읽기 결과의 `section_path`도 그대로 전달한다. 문단 좌표를 쓰는 경우 셀 채움 전에 수행하고 서로 겹치는 변경은 피한다. 셀의 기존 문단 수를 넘는 새 줄·서식 자동 축소는 기본 내용 채움에 포함하지 않는다. 원시 ZIP/XML을 직접 쓰지 않는다.

```powershell
& .agent/shared/Invoke-HwpxEditPlan.ps1 -JobPath $job.jobPath -PlanPath $plan -SourceSha256 $sourceHash -DryRun
& .agent/shared/Invoke-HwpxEditPlan.ps1 -JobPath $job.jobPath -PlanPath $plan -SourceSha256 $sourceHash
```

오류·중단이 발생하면 [편집 계획/복구](../../../../.agent/shared/HWPX-EDIT-PLAN.md)의 상태와 저장 여부부터 확인한다. 같은 실패 호출을 반복하지 않는다.

## 확인과 게시

ODT 공문은 [공문 스킬](../../../../.agent/shared/official-odt-draft/SKILL.md)의 보존 편집을 사용한다. 다른 파일 형식은 해당 스킬을 사용하며 HWPX 도구를 추가하지 않는다.

저장본을 한 번 읽어 실제 채운 핵심값·반복값·해당 합계와 요청 밖 내용 보존을 확인한다. 서류와 공문을 함께 만들었으면 붙임 제목·수량이 실제 결과 파일과 맞는지도 이때 확인한다. 실행기의 저장·재열기·무결성 성공 기록을 재사용한다. 전항목 대조표·별도 보고서·PDF 렌더·문안 자동 보완 반복을 기본 과정에 넣지 않는다. 명백한 오입력이나 저장 실패는 해당 부분만 바로잡는다.

실제로 `content`와 `integrity` 확인을 마쳤을 때만 다음을 실행한다. 이 명령은 기존 완료·게시 게이트를 함께 호출하며 검사를 대신하지 않는다.

```powershell
& .agent/shared/Publish-DocumentDraft.ps1 -JobPath $job.jobPath `
  -SourceFile $savedDrafts -TargetRelativePath $resultNames `
  -ChecksCompleted content,integrity -FormBaseFile $hwpxBases `
  -FormContractPath "$($job.jobPath)/wip/receipts/hwpx-form-contract.json"
```

HWPX가 없으면 `FormBaseFile`과 `FormContractPath`를 생략한다. `$hwpxBases`는 계약의 기준 양식과 같은 순서다. `$savedDrafts`와 `$resultNames`도 같은 순서로 대응한다. 결과 이름은 `신청서.hwpx`, `제출공문.odt`처럼 지정하면 설정된 Output에 번호를 붙인다. 게시 이름에 `초안`, `검토용`, `draft`, `v1`을 넣지 않으며 Review 상태는 메타데이터와 채팅으로 전달한다. 기존 현재 경로·번호는 유지한다. 실제 게시 경로, 확인 범위, 남은 보완사항 최대 3개를 채팅으로 알린다. 저장 성공을 실제 한컴 화면·결재·제출 확인으로 보고하지 않는다.
