# Hanword forms and editing

Read only for HWP/HWPX/HWTX work. The local workflow governs authority/delivery; the installed HWPX skill governs document tools.

## Form authority

Open and reuse an existing draft or form, including a completed predecessor. Prefer the user-designated draft/form, then the registered current human document, then an explicitly selected prior document. For a remaining prior-material gap, pass only user-designated directories through `Find-HwpxContext.ps1 -PriorFolder`; do not infer a prior library or year folders. Search only until the form and current factual authority suffice. Register selected prior material through intake and fill its new work copy while preserving its layout. Another job's output requires an explicit authority decision.

Preserve combined document boundaries and explicit replication variants. Missing blank templates do not mean no usable form exists: a selected completed document can provide the existing structure. If both draft and form are absent, stop dependent authoring and request an existing draft/form. Stop and request a readable file or a selection when candidates are unreadable or ambiguous. Do not invent a layout or bypass this requirement through “no materials”, “new draft”, “final version”, generic bundled assets, or a free-layout instruction. Bundled blank assets require the user's explicit selection before use. Current dates, people and document numbers need current evidence rather than inheritance from the predecessor.

Before form-like authoring, use `New-HwpxFormContract.ps1` to create the single `wip/receipts/hwpx-form-contract.json`. Set authority, required values, combined/separate boundaries and variants. Output count is form units multiplied by explicit variants; 강좌별/학년별/주간·야간별 usually replicates the complete form rather than splitting internal sections.

## Tool route

For whole-document concatenation, follow the tested [native merge workflow](../../../../.agent/shared/hancom-native/WORKFLOW.md): ordered input list → prepare plan → run merge → existing publication gates. This uses Hancom's native document insertion and the user-approved official automatic-access module. It needs no preliminary HWP conversion, blueprint reconstruction, table-by-table analysis or HWPX MCP installation check. Keep formatting unchanged; the worker handles hashes, native reopening, content order, package validation, time limits and matching receipt reuse. Other document edits continue through the routes below.

Normalize only selected Hanword inputs with `Convert-SelectedInputsToHwpx.ps1` into `wip/docs/normalized/`, keeping the receipt/canonical base. HWP originals are immutable; HWTX requires instantiation. Never edit ZIP members or raw OWPML XML. Follow [the Windows runtime skill](../../../../.agent/shared/hwpx-runtime/SKILL.md) for tool routing: check MCP health once per session only when the MCP tools are callable, and otherwise use its verified local read/edit routes. Recheck only when a concrete failure or capability/version change makes the prior check stale. Document work does not trigger installation or update diagnostics.

Use bounded reading from the runtime skill and reuse saved maps while the document revision matches. If the target table is already identified, read it directly; a fresh summary map adds a call and is not always faster for small documents. Inspect the selected structure, then batch unambiguous ordinary text/cell updates with supported `run_edit_plan`. Retain semantic/specialist routes for structural or identity-dependent work and their mandatory dry-run/open-safety requirements. Cross-check relevant facts elsewhere in the document during the initial read. Use [the durable adapter](../../../../.agent/shared/HWPX-EDIT-PLAN.md) only when persistent timing/recovery receipts are needed. If an operation stalls, establish whether it is still writing or has already saved before retrying or switching routes.

Content-only edits fill existing targets without visual tuning. Use the approved form contract and fixed targets; do not ask the language model to recreate the layout. Check target capacity and required values before declaring completion. If text cannot fit the approved field structure, stop that fill and resolve the content length or explicitly requested format change; do not silently drop lines, shrink fonts or invent a new layout. The operation gate checks directly addressed cells against existing paragraph slots before content-only fills. Anchor targets and explicitly allowed format edits still need an output content check; a successful operation is not proof that all text survived. Preserve human wording and formatting outside named targets. A tool decision point does not imply another user approval. Follow [content and formatting scope](../SKILL.md#내용과-서식-범위) and mandatory specialist safety contracts.

## Publication evidence

For explicitly requested whole-subject replacement inside a grade compilation, use the [native subject replacement workflow](../../../../.agent/shared/subject-replacement/WORKFLOW.md). Its separate publication route verifies current-base/source hashes, native full-text replacement, subject order, table text/topology/geometry and package safety. Do not pass its receipt as a whole-document merge or copy-and-fill receipt.

Supply the canonical form contract, normalized base and normalization receipt when applicable. Establish:

- Correct current authority, required values, output count/variants and structural lineage with combined/separate boundaries preserved.
- Unchanged source/intake human revisions and successful reopen/open-safety; visual evidence when explicitly authorized or required by a specialist contract.
- Official filenames, registered current set and preserved selected source revisions.

`FormGateNotApplicable` is only a technical exception to the HWPX-specific contract for a genuinely non-form document with a concrete reason. It does not waive the existing draft/form requirement. A matching successful receipt satisfies the same check; no second identical verification loop is needed.
