---
name: hwpx-workspace-delivery
description: 기존 초안·양식을 먼저 확인해 학교 문서·표·텍스트 문안을 채우고, 업무별 자료 선택·파일 접수·수정·게시와 요청된 업무현황 HTML 보고를 처리한다. 질문·분석·자료 읽기·업무순서 배치만 하는 요청은 제외한다.
---

# 학교 문서 처리

이 스킬은 업무폴더·기준자료·접수·게시를 담당하고, 형식별 전문 스킬은 문서 내용과 편집을 담당한다. 이미 선택한 업무·자료·진행 중 job을 이어 쓴다. 초안 수정과 재시도는 내부 작업공간에서 처리하고 요청한 결과 집합이 완성되면 한 번 게시한다. 전문 스킬에서 이 경로를 다시 참조해도 같은 접수나 완료된 검사를 다시 시작하지 않는다. 입력·요청 범위가 바뀌면 영향받는 부분만 갱신한다.

HWPX·ODT·DOCX·XLSX·CSV와 텍스트 문안 등 모든 산출물은 기존 초안이나 양식을 먼저 열어보고 내용만 채운다. 우선순위는 사용자 지정 초안/양식, 등록된 현재본, 명시적으로 선택한 이전 문서다. 완료된 문서도 기존 구조의 기준으로 쓸 수 있다. 현재 근거를 확인해 필요한 내용만 바꾸고 새 양식을 만들지 않는다. 기준본이 없거나 읽을 수 없거나 선택이 모호하면 그 기준에 의존하는 작성을 멈추고 사용자에게 초안/양식 또는 선택을 요청한다. ‘자료 없이 시작’, ‘새 초안’, ‘최종본’과 범용 빈 assets는 기준본 요구를 대신하지 않는다. 질문·분석·업무계획 논의에는 이 요구를 적용하지 않는다. 선택 절차는 [기준자료 선택](references/reference-scope.md)을 따른다.

사용자가 파일을 제공하면 문서 접수 전이라도 `Receive-TeacherHarnessInputs.ps1`로 설정된 받은자료에 원본 사본을 보관한다. 접근할 수 없는 첨부는 저장했다고 말하지 않고 접근 가능한 로컬 경로를 요청한다. 실제 문서 접수의 `-UserProvidedFile`도 자동 보관과 연결하며 [접수와 게시](references/artifacts.md)의 역할별 기록을 유지한다.

명령은 `.agent/shared/`, 경로 설정은 `.agent/index/delivery-system.json`에 있다. PowerShell은 `powershell -NoProfile -ExecutionPolicy Bypass -File <경로> <인자>`로 실행한다.

## 요청에 맞는 경로

필요한 행의 지침만 읽는다. 참고자료의 형식 때문에 산출물 형식을 바꾸거나 추가하지 않는다.

| 작업 | 사용할 지침 |
|---|---|
| 기준자료 선택만 저장·변경 | [기준자료 선택](references/reference-scope.md); 문서 접수·탐색·작성은 시작하지 않음 |
| 실제 파일 작성·수정·게시 | [접수와 게시](references/artifacts.md); 이 문서에서 업무폴더와 기준자료로 연결 |
| HWP/HWPX/HWTX 편집 | 설치된 HWPX 스킬과 [한글 실행 경로](references/hanword.md) |
| 파일 전체 이어붙이기 | [네이티브 병합](../../../.agent/shared/hancom-native/WORKFLOW.md); 일반 양식 채우기 경로는 겹쳐 실행하지 않음 |
| 같은 한글 표의 명단 취합 | [명단 취합](../../../.agent/shared/collect-hwpx-rosters/SKILL.md) |
| 비정형 근거로 값 채움·대조 | 설치된 `evidence-fill-check` 스킬 |
| 공문·기안문 파일 작성 | 설치된 `official-odt-draft` 스킬; 기본 ODT |
| 업무순서·번호 배치도 함께 변경 | [work-planning](../work-planning/SKILL.md); 이미 정한 업무·job을 공유 |
| 검사 범위 / 작업본 정리 | [검증](references/verification.md) / [문서 보관](references/storage.md) |

## 내용과 서식 범위

후속 수정은 등록된 사람 현재본과 접수 해시에서 시작하며 요청 밖의 사람 수정·문구·서식은 보존한다. 파일명·예시·전년도 양식으로 올해 사실이나 공식 권한을 추정하지 않는다.

Review/Final 모두 기본은 `content_only`다. “최종본·제출용·계속·병합”이나 에이전트의 품질 판단은 서식·시각 검사 허가가 아니다. 일반 작성·취합은 내용·파일 무결성 검사에서 끝낸다. 선택한 전문 연산의 필수 재열기·무결성 검사는 유지하되 외관 검사로 확대하지 않는다.

서식 수정은 실제 사용자 요청의 해당 긍정 문장을 그대로 `Start-HwpxWork.ps1 -FinalPolishAuthorized -FormattingRequestText '<요청 원문>'`에 기록한다. 시각 검사·PDF 렌더는 별도로 `-VisualReviewAuthorized -VisualReviewRequestText '<요청 원문>'`을 기록한다. 스위치 단독·대리 요약·허가 문구 발명은 금지한다. 허가는 job의 `inputs.json.documentScope`와 현재 업무 메타의 동일 scope에만 유효하며 다른 job으로 전파하지 않는다. 같은 요청을 재개할 때 기존 명시 허가는 유지한다. 새 `RequestText`/`RequestId`로 접수한 요청은 기본 내용 수정으로 시작하고 필요한 서식·시각 허가를 그 요청에서 다시 구분한다. 사용자 요청이 이어지면 기존 근거를 그대로 사용할 수 있으나 일반 내용 수정에 서식 권한을 자동 전파하지 않는다. 사용자가 범위를 철회·축소하면 `-RevokeDocumentScope`로 먼저 철회한다. 원문이 이미 있으면 재확인을 요구하지 않고 그 근거를 사용한다. “서식 다듬기”를 임의로 추가해 게시 게이트를 통과시키지 않는다.

지원 편집은 공통 실행기를 사용한다. 직접 MCP 편집이 필요한 경우에도 저장한 plan에 `Assert-DocumentOperationScope.ps1 -JobPath <job> -Capability edit_plan -PlanPath <plan>`을 먼저 적용한다. 허가 없는 셀 자동 글꼴 축소·행높이·간격·여백·쪽 조정 및 선택적 렌더를 수행하지 않는다. 범위 게이트의 거부를 직접 Python·COM·MCP 호출로 우회하지 않는다. 허가된 시각 검사는 해당 요청 범위의 쪽만 확인한다. 사용자 요청 원문·해시는 근거 누락과 변경을 찾는 장치이며 인간 인증이나 OS 권한 격리를 대신하지 않는다.

Review/Final은 내용 단계이며 결재·제출·통지·운영 완료는 실제 근거가 필요하다. 결과는 채팅으로 보고하고 요청 없는 현황판·설명 TXT는 만들지 않는다.

## Console communication and requested artifacts

업무현황 HTML에 반영해 달라는 요청은 [콘솔 보고](references/console-report.md)를 사용한다. 채팅에서 진행 상황만 묻는 요청은 게시하지 않는다. 보고만 할 때 문서 접수·새 계획·유지보수 검사를 시작하지 않는다. 일반 파일 작업의 `-UpdateConsole`도 HTML 생성·갱신 요청이 있을 때만 사용한다. 기존 HTML의 존재는 갱신 요청이 아니다.
