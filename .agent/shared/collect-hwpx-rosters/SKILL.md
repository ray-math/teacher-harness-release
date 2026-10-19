---
name: collect-hwpx-rosters
description: 같은 한글 표로 제출된 과목별 학생 명단을 HWPX 한 파일에 취합하고 명렬표로 학번·성명을 대조·정렬한다.
---

# Collect subject rosters

Use for populated rows from copies of the same Hanword table. Checking existing values without collection uses [evidence-fill-check](../evidence-fill-check/SKILL.md); whole-document append uses the [native merge workflow](../hancom-native/WORKFLOW.md).

Output is HWPX in the existing form. XLSX may supply comparison data. Follow [delivery](../../../.agents/skills/hwpx-workspace-delivery/SKILL.md) for intake/publication and [Windows runtime](../hwpx-runtime/SKILL.md) for HWPX routing. Ordinary collection preserves formatting and ends at content/integrity plus publication gates; no routine Hancom launch, PDF export or visual review. An explicitly requested console-only report follows delivery's report route without running this writer or creating collection config.

## Configure and run

Prepare one job-local `collection.json` using [config.md](config.md), selected live inputs and normal intake. Inspect the reference roster layout to map its sheet, columns and ID convention. Map known subject-label differences explicitly; do not guess a semester or ID convention. Use the current human result for follow-up, or a submitted combined form for first collection, with its normal form contract.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Invoke-HwpxRosterCollection.ps1 -ConfigPath <job>/collection.json
```

The runner owns the following operations and evidence; do not reproduce them through a second manual extraction:

- `source_diff` verifies matching headers, row labels and cell coordinates, retaining common cells once and source-associated differences in `wip/analysis/source-diff.json`.
- Nonempty student cells and explicit `없음` identify submitted rows. Adopt the student list, selection criterion and teacher from that row together. A teacher in another file's unfilled row is a template default. Multiple populated submissions for one subject require a source decision; frequency is not authority.
- Every populated subject row is collected, including several in one file. IDs/names are matched, absent IDs supplemented only by unique name matches, and records sorted numerically. Supplied conflicting IDs, duplicate submissions and unmatched subjects stop with local evidence. Blank/unsubmitted is not zero. Put user-provided known counts in `expectedCounts`; a disagreement must not be fixed by padding a roster.
- `merge_diff` compares selected records with the base and records changed cells' before/after/source in `wip/analysis/merge-diff.json`. Equal ordered lists retain separators/line breaks, including trailing commas. Zero content changes mean no edit. Changed cells are applied through one public edit plan and verified together with unchanged cells.

The reader's source-completeness audit preserves text after inline line breaks (`lineBreak.tail`) that installed map/text APIs can omit. Agreement between those APIs alone is insufficient. Read-only traversal differences stay local; all editing uses public HWPX operations, without writing ZIP/XML members.

## Complete the collection

Successful output includes compact counts and `wip/receipts/collection.json`. Matching successful inputs/output hashes reuse that result. Changed inputs require fresh intake and a separate draft/job; preserve existing results instead of deleting them to force a rerun. Student details stay in job-local analysis, never chat or a general index.

Publish with `Publish-HumanResult.ps1`, the existing form contract and `wip/docs/base.hwpx`. Preserve unrelated human files; an erroneous earlier output format is archived through normal publication when replaced by the requested format. Use [CHECK-WORKFLOW.md](../../../.agents/skills/hwpx-workspace-delivery/references/verification.md) for completion: source records, changed/unchanged cells and relevant omissions/duplicates/counts plus runner/publishing receipts. Passing those gates ends ordinary collection; developer regression tests apply when the tool itself changes.

Report the actual content checkpoint and verification level. Final is not official approval/submission or school-operation completion; a console report is not proof of document integrity/publication.
