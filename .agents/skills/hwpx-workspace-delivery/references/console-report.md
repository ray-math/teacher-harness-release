# 요청된 콘솔 보고

업무현황 HTML 생성·갱신을 요청한 경우에만 적용한다. 채팅 보고는 게시하지 않는다. [업무폴더 선택](work-folder.md)으로 기존 대상을 확인하고, 이미 선택된 업무와 job은 재사용한다. 설치된 콘솔 실행기가 필요하며 보고 요청 때문에 도구를 자동 설치하거나 유지보수 검사를 실행하지 않는다.


Missing registered files or unregistered root files do not block a requested report. Report the registration differences without reconciling, deleting or giving authority to those files. This exception is only for reporting; artifact intake/publication retains its own gates.

Use `Publish-HumanResult.ps1 -ConsoleContentPath <report.json> -WorkFolderName <YYYYMMDD_title>` (or a unique `-TaskTitle`). This parameter set takes no `-Stage`, `-SourceFile` or `-ReviewQuestion`: it preserves document stage, review state and workflow. Input JSON belongs in the selected work job; the publisher validates it and stores a recovery-backed receipt.

The input JSON is the `consoleContent` object itself. The registered mode stores it under `consoleContent` in the work folder's `.ai/work.json`, and the existing `Update-HumanWorkConsole.ps1` generator renders its sections in the same `업무현황.html`:

```json
{
  "schemaVersion": "hwpx-console-content/v1",
  "sections": [
    {"id": "analysis", "title": "분석 결과", "body": "확인한 사실과 근거 위치"},
    {"id": "questions", "title": "확인할 사항", "body": "미확정 질문과 필요한 근거"},
    {"id": "next-actions", "title": "다음 행동", "body": "요청 범위 안에서 이어서 할 일"},
    {"id": "review", "title": "검토", "body": "내용 검토 결과와 실제 검증 수준"}
  ]
}
```

- `schemaVersion` must equal `hwpx-console-content/v1`; `sections` is an ordered array of objects with stable unique nonempty string `id`, nonempty string `title`, and string `body`. Choose only sections needed for the report; the example is not a mandatory four-section template. Preserve an ID when revising the same topic.
- Optional `presentation: "message"` renders body lines with explicit `<br>` boundaries and bolds only a leading `[1학년 과목]`, `[2학년 과목]`, or `[3학년 과목]` label. Text remains escaped. A user-clicked copy button offers both CRLF plain text and formatted HTML; other sections are unchanged.
- Optional `tables` is an array of `{caption, columns, rows}`. `caption` is nonempty plain text; `columns` is a nonempty array of plain-text headers; `rows` is an array of string arrays with exactly one cell per column. The generator emits semantic HTML tables and escapes every caption/header/cell; raw HTML remains forbidden. Existing sections without tables are unchanged.
- Optional `references` is an array of `{path, sha256, locator}` with an absolute registered source path, its selected SHA256 and a nonempty source locator. The publisher verifies registered source revisions.
- Sections appear expanded in Home before the file list, preserving existing tab IDs and workflow checkbox keys.
- Titles and bodies are plain text, HTML-escaped by the generator, with body newlines preserved. Never interpret report text as raw HTML, script or an arbitrary launch URL. Document-open links come from the existing manifest, not executable text or unvalidated paths embedded in `body`.
- Communication-only publication registers report content and its update receipt, then regenerates the affected console. It needs no school artifact, source-file placeholder, form discovery, HWPX health check or document intake. Resolve the intended work folder and title through the supported registration path; do not invent a second dashboard or manually write authority metadata.
- Existing current-file registration, source authority, document bytes, hashes and revision history remain unchanged. Retain the existing workflow unless its change is requested or supported by newly reviewed evidence. Document authority/form/open-safety gates still apply to actual artifact publication; console-only mode cannot serve as a bypass for replacing files.
- Checking stays read-only unless the user asks to report in the console. That request authorizes this registered report update only. Ordinary chat reports do not trigger publication, console refresh or work-folder creation.
- Review/Final and report completion describe content readiness for the requested checkpoint. They do not certify school approval, submission, notification or operational completion. State pending official actions honestly; neither browser checkboxes nor a report receipt prove they occurred.

`-ExplicitTextArtifact` is required for TXT artifact publication. Supply it only when the user explicitly requested a TXT deliverable. Explanations use chat by default; use console content only when the user explicitly asks for a console report.

기존 업무의 `.ai/work.json.commonRecord.enabled`가 켜져 있으면 [공통 시험 기록 모드](console-record.md)도 필요한 변경에만 적용한다. 일반 업무에는 읽지 않는다.
