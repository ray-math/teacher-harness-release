---
name: hwpx-workspace-delivery
description: 기존 학교 문서·양식에 내용을 채우고 수정본을 저장·게시한다. 기준자료 선택, 후속 수정, 요청된 업무현황 HTML도 다룬다. 질문·자료 읽기·업무순서 논의만 하는 요청은 제외한다.
---

# 학교 문서 처리

기본 목표는 **쓸 수 있는 초안을 저장하고, 한 번 확인한 뒤 남은 보완사항을 제안하는 것**이다. “이 자료를 보고 이 형식에 맞춰 올해 내용으로 바꿔 줘”로 충분하며 사용자에게 모드·경로·검사 옵션을 추가하게 하지 않는다. AGENTS의 기준본 우선순위, 원본·사람 수정 보존, 출력 경로 규칙을 따른다. 올해는 요청 시점의 연도이며 사용자가 정한 업무연도·시연 기준일이 있으면 그것을 쓴다.

일반 초안은 [짧은 실행 안내](references/draft-quickstart.md)를 읽는다. 필요한 자료를 읽어 작성 가능한 부분을 채우고 Review로 게시한다. 같은 업무·job과 성공한 읽기/검사 기록을 재사용하며 전문 스킬을 참조했다고 접수를 반복하지 않는다. 문안 확장이나 미확정 사실은 후속 작업으로 제안하고, 명백한 오입력·저장 실패·서식 훼손만 바로잡는다. 초안은 전항목 완료나 결재·제출 완료가 아니다.

## 필요한 경우에만 읽기

| 요청·상황 | 지침 |
|---|---|
| 비정형 근거 값을 채우거나 대조 | [근거 채움](../../../.agent/shared/evidence-fill-check/SKILL.md) |
| 공문·기안문 | [공문 처리](../../../.agent/shared/official-odt-draft/SKILL.md) |
| HWP/HWTX 변환·특수 한글 편집 | 설치된 HWPX 스킬과 [한글 경로](references/hanword.md) |
| 파일 전체 이어붙이기 / 같은 양식 명단 취합 | [네이티브 병합](../../../.agent/shared/hancom-native/WORKFLOW.md) / [명단 취합](../../../.agent/shared/collect-hwpx-rosters/SKILL.md) |
| 기준자료 선택만 저장·변경 | [기준자료 선택](references/reference-scope.md); 문서 작성을 시작하지 않음 |
| 후속 수정·부분 파일 변경·기존 자동 보관 설정 | [접수와 게시](references/artifacts.md) |
| 엄격검증 / 작업본 정리 | [검증](references/verification.md) / [보관](references/storage.md) |
| 업무순서·번호 배치 변경 | [업무 설계](../work-planning/SKILL.md) |
| 업무현황 HTML 생성·갱신 요청 | [콘솔 보고](references/console-report.md) |

참고자료의 형식 때문에 결과 형식을 바꾸거나 추가하지 않는다. 일반 작성에 설치·전체 회귀검사·별도 설명 파일을 추가하지 않는다. 환경 확인이 필요한 시연·장애 상황에만 `Test-DocumentWorkReadiness.ps1`을 사용한다.

## 내용과 서식 범위

기본은 `content_only`다. “최종본·제출용·계속”은 서식 수정·시각 검사 허가가 아니다. 지원 편집 실행기의 해시·범위·무결성·재열기 검사는 유지하고, 일반 초안에 PDF·스크린샷·글꼴 축소·행높이 조정을 추가하지 않는다. 직접 MCP 편집도 저장한 plan에 `Assert-DocumentOperationScope.ps1 -JobPath <job> -Capability edit_plan -PlanPath <plan>` 검사를 먼저 적용한다. 범위 거부를 직접 Python·COM·MCP 편집으로 우회하지 않는다.

서식 수정은 실제 사용자 요청의 긍정 문장을 `Start-HwpxWork.ps1 -FinalPolishAuthorized -FormattingRequestText`로, 시각 검사는 별도로 `-VisualReviewAuthorized -VisualReviewRequestText`로 기록한다. 원문이 이미 있으면 재확인을 요구하지 않는다. 허가를 발명·대리 요약하거나 다른 요청·job에 자동 전파하지 않는다. 같은 요청 재개는 기존 근거를 유지하며 범위 철회는 `-RevokeDocumentScope`로 기록한다. 전문 연산의 필수 검사도 해당 요청 범위에 적용한다.

## 재개와 완료 보고

중단 후에는 현재 파일·해시와 마지막 성공 영수증을 확인하고 그다음 단계부터 이어간다. 과거의 사용량 제한·승인 서비스 오류를 현재 거부로 보고하지 않으며 실제 권한·안전성 거부는 우회하지 않는다. 새 호출이 실패하면 새 오류를 보고한다.

결과 위치·실제 확인 범위·남은 항목 최대 3개를 채팅으로 알린다. 요청 없는 현황판·설명 TXT는 만들지 않는다. 기존 HTML이 있다는 이유로 갱신하지 않으며 진행 상황 질문에는 채팅으로 답한다.
