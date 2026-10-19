# Durable simple edits

Use `Invoke-HwpxEditPlan.ps1` for already mapped ordinary text/cell changes requiring persistent progress and recovery. It invokes the same public `HwpxOps.run_edit_plan` implementation and fixed Windows runtime as HWPX MCP; `.agent/index/hwpx-runtime.json` specifies the versions. It does not patch installed packages or write ZIP/XML members. Launch uses the installed Python directly, without uv resolution, network access or automatic updates. See [the runtime skill](hwpx-runtime/SKILL.md).

Save a supported `hwpx.edit-plan/v1` JSON in the active job. Before execution or receipt reuse, the adapter checks the job's document scope. Content-only plans permit the tested text operations and argument keys; row heights, formatting and automatic font fitting require explicit `format_edit` evidence. Unknown nested operations/keys do not silently inherit content-only permission. `-Status` remains read-only inspection of execution state. Group text changes in one `apply_body_ops` step and cell changes in one `fill_cells` step where appropriate. Use exact expected match counts; ambiguous targets require narrower discovery. Structural/identity-dependent changes retain the semantic or specialist workflow. Do not mechanically convert arbitrary semantic commands to text replacements.

```json
{
  "schemaVersion": "hwpx.edit-plan/v1",
  "source": "C:/.../selected-base.hwpx",
  "output": "C:/.../YYYYMMDD_work/.ai/jobs/YYYYMMDD-job/wip/docs/result.hwpx",
  "steps": [{
    "id": "text_updates",
    "op": "apply_body_ops",
    "args": {"ops": [{"op": "replace_text", "find": "기존 문구", "replace": "수정 문구", "count": 1}]}
  }]
}
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .agent/shared/Invoke-HwpxEditPlan.ps1 -JobPath <active-job> -PlanPath <plan.json> -SourceSha256 <intake-sha256> -DryRun
# After the matching dry-run succeeds, repeat without -DryRun to commit.
# -Status reads durable state; -TimeoutSeconds defaults to 120 and stops a timed-out worker.
```

The source is locked against writes/deletes during execution and must match the supplied intake hash. The output must be a separate HWPX under the school job's `wip`, and must not already exist. Use the job path returned by intake, within the human work folder. A completed identical invocation returns its receipt. If a changed plan requires a distinct destination, preserve the canonical draft and its receipt within that same work; do not proliferate `.agent` copies. Final polishing and specialized mandatory visual checks remain separate applicable gates.

Receipts live under `wip/receipts/edit-<request hash>/`:

- `plan.json` / `request.json`: exact plan, source hash, dry-run mode and recovery parameters.
- `state.json`: phase, start/update times, PID, timings, save status and output hash.
- `engine-report.json` / `journal.jsonl`: complete upstream step, preservation, reopen and open-safety evidence. These can contain local document values; do not copy them into chat or broad indexes.
- `worker.log`: diagnostic exceptions and runtime messages.

Timing phases are analysis, edit including the engine's per-step checks, final validation, candidate save and output publication. They are not a claim to isolate every validation cost. No real Hancom render is implied by reopen/open-safety receipts.

Recovery uses the same plan, source hash and mode. `saved` with a matching output hash is reusable, including recovery after a process ended between saving and writing its final receipt. `interrupted_before_publish` means the requested output was not written; a verified source can be processed again. A running worker is protected by a process-held lock. `output_conflict_or_unknown` or `output_missing` needs inspection; the adapter refuses to overwrite or blindly repeat. Failed steps leave source and requested output unchanged. A supported fallback is direct MCP `run_edit_plan` using the persisted plan only after the prior worker has stopped and save state is known; retain the same source revision and all applicable gates.
