"""Read one explicitly selected Codex rollout; print metadata, never its content.

Usage totals come only from token_usage_record.payload.usage. Input includes
cached and cache-write subsets; output includes the reasoning subset. Completed
turn duration is elapsed wall time (including waits), not CPU or active work.
Text sizes count string values, decoding JSON containers where possible and
omitting typed media, binary fields, and data URIs. They are not token estimates.
"""

import argparse
from collections import Counter, OrderedDict
from datetime import datetime
import json
from pathlib import Path
import re
import sys


TOKEN_FIELDS = (
    "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
    "output_tokens", "reasoning_output_tokens", "total_tokens",
)
CALL_TYPES = {"function_call", "custom_tool_call"}
OUTPUT_TYPES = {"function_call_output", "custom_tool_call_output"}
SKIP_FIELDS = {
    "data", "base64", "b64_json", "blob", "bytes", "image", "image_url",
    "audio", "audio_url", "file_data", "reasoning", "reasoning_content",
    "encrypted_content", "type", "id", "call_id", "name", "mimetype",
    "mime_type", "detail", "annotations", "_meta",
}
DATA_URI = re.compile(r"data:[^\s\"'<>]*", re.IGNORECASE)


def iso_time(value):
    """Require an explicit timezone so cutoff results do not depend on the host."""
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp requires a timezone")
    return result


def text_chars(value):
    """Count textual values without exposing them or interpreting them as tokens."""
    if isinstance(value, str):
        stripped = value.lstrip()
        if stripped.startswith(("{", "[")):
            try:
                decoded = json.loads(value)
            except (ValueError, RecursionError):
                pass
            else:
                if isinstance(decoded, (dict, list)):
                    return text_chars(decoded)
        return len(DATA_URI.sub("", value))
    if isinstance(value, list):
        return sum(text_chars(item) for item in value)
    if isinstance(value, dict):
        kind = str(value.get("type", "")).lower()
        if any(word in kind for word in ("image", "audio", "video", "reasoning")):
            return 0
        return sum(text_chars(item) for key, item in value.items()
                   if key.lower() not in SKIP_FIELDS)
    return 0


def nonnegative_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def new_turn(turn_id):
    return {
        "turn_id": turn_id, "completed": False, "wall_duration_ms": None,
        "responses": 0, "tool_calls": 0, "tool_outputs": 0,
        "tool_call_text_chars": 0, "tool_output_text_chars": 0,
        "tokens": {name: None for name in (*TOKEN_FIELDS, "uncached_input_tokens")},
    }


def add_known(target, field, value):
    if value is not None:
        target[field] = (target[field] or 0) + value


def summarize(rollout, before=None, last_turns=20):
    """Stream exactly one file; return only identifiers, counts, and warnings."""
    if isinstance(before, str):
        before = iso_time(before)
    if last_turns < 1:
        raise ValueError("last_turns must be positive")
    turns = OrderedDict()
    issues = Counter()
    totals = Counter()
    seen_usage = {}
    call_turns = {}
    active_turn = None
    session_id = None

    def turn(identifier):
        key = identifier if isinstance(identifier, str) and identifier else "(unassigned)"
        if key not in turns:
            turns[key] = new_turn(key)
        return turns[key]

    with Path(rollout).open("r", encoding="utf-8-sig") as stream:
        for line in stream:
            totals["lines_read"] += 1
            try:
                record = json.loads(line)
            except (ValueError, RecursionError):
                issues["invalid_json_records"] += 1
                continue
            if not isinstance(record, dict):
                issues["invalid_record_objects"] += 1
                continue
            if before is not None:
                try:
                    timestamp = iso_time(record.get("timestamp", ""))
                except (ValueError, TypeError, AttributeError):
                    issues["records_skipped_missing_or_invalid_timestamp"] += 1
                    continue
                if timestamp >= before:
                    totals["records_at_or_after_cutoff"] += 1
                    continue
            totals["records_in_scope"] += 1
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            record_type = record.get("type")
            kind = payload.get("type")
            if record_type == "session_meta":
                identifier = payload.get("id")
                if isinstance(identifier, str) and identifier:
                    session_id = identifier
            elif record_type == "turn_context" or (record_type == "event_msg" and kind == "task_started"):
                identifier = payload.get("turn_id")
                if isinstance(identifier, str) and identifier:
                    active_turn = identifier
                    turn(identifier)
            elif record_type == "event_msg" and kind == "task_complete":
                item = turn(payload.get("turn_id"))
                duration = nonnegative_int(payload.get("duration_ms"))
                if item["completed"]:
                    issues["duplicate_completion_records"] += 1
                    if duration != item["wall_duration_ms"]:
                        issues["conflicting_completion_records"] += 1
                else:
                    item["completed"] = True
                    item["wall_duration_ms"] = duration
                    if duration is None:
                        issues["completed_turns_missing_valid_duration"] += 1
                if active_turn == payload.get("turn_id"):
                    active_turn = None
            elif record_type == "token_usage_record":
                totals["usage_records"] += 1
                if session_id is not None and payload.get("thread_id") != session_id:
                    if payload.get("thread_id"):
                        totals["usage_records_from_other_threads_excluded"] += 1
                    else:
                        issues["usage_records_excluded_missing_thread_identity"] += 1
                    continue
                identifier, response = payload.get("turn_id"), payload.get("response_id")
                if not all(isinstance(value, str) and value for value in (identifier, response)):
                    issues["usage_records_excluded_missing_identity"] += 1
                    continue
                usage = payload.get("usage")
                usage = usage if isinstance(usage, dict) else {}
                counters = {field: nonnegative_int(usage.get(field)) for field in TOKEN_FIELDS}
                key = (identifier, response)
                if key in seen_usage:
                    totals["duplicate_usage_records_ignored"] += 1
                    if counters != seen_usage[key]:
                        issues["conflicting_duplicate_usage_records_first_kept"] += 1
                    continue
                seen_usage[key] = counters
                item = turn(identifier)
                item["responses"] += 1
                for field, value in counters.items():
                    add_known(item["tokens"], field, value)
                    if value is None:
                        issues["responses_missing_" + field] += 1
                inp, cached, written = (counters[field] for field in TOKEN_FIELDS[:3])
                if all(value is not None for value in (inp, cached, written)):
                    if cached + written <= inp:
                        add_known(item["tokens"], "uncached_input_tokens", inp - cached - written)
                    else:
                        issues["responses_with_invalid_input_cache_subsets"] += 1
                else:
                    issues["responses_missing_uncached_input_basis"] += 1
                out, reasoning, total = (counters[field] for field in TOKEN_FIELDS[3:])
                if out is not None and reasoning is not None and reasoning > out:
                    issues["responses_with_reasoning_exceeding_output"] += 1
                if inp is not None and out is not None and total is not None and inp + out != total:
                    issues["responses_with_total_mismatch"] += 1
            elif record_type == "event_msg" and kind == "token_count":
                totals["token_count_records_ignored"] += 1
            elif record_type == "response_item" and kind in CALL_TYPES | OUTPUT_TYPES:
                call_id = payload.get("call_id")
                identifier = payload.get("turn_id") or active_turn
                if kind in OUTPUT_TYPES and isinstance(call_id, str):
                    identifier = call_turns.get(call_id, identifier)
                item = turn(identifier)
                if kind in CALL_TYPES:
                    item["tool_calls"] += 1
                    content = payload.get("arguments") if kind == "function_call" else payload.get("input")
                    item["tool_call_text_chars"] += text_chars(content)
                    if isinstance(call_id, str):
                        call_turns[call_id] = item["turn_id"]
                else:
                    item["tool_outputs"] += 1
                    item["tool_output_text_chars"] += text_chars(payload.get("output"))

    total_tokens = {field: None for field in (*TOKEN_FIELDS, "uncached_input_tokens")}
    for item in turns.values():
        for field, value in item["tokens"].items():
            add_known(total_tokens, field, value)
        for field in ("responses", "tool_calls", "tool_outputs", "tool_call_text_chars", "tool_output_text_chars"):
            totals[field] += item[field]
        if item["completed"]:
            totals["completed_turns"] += 1
            if item["wall_duration_ms"] is not None:
                totals["completed_turn_wall_ms"] += item["wall_duration_ms"]
        else:
            issues["turns_without_completion_record"] += 1
        if not item["responses"]:
            issues["turns_without_usage_records"] += 1
    if "(unassigned)" in turns:
        issues["unassigned_turn_bucket"] += 1
    if not turns:
        issues["no_turn_metadata_found"] += 1
    totals["turns"] = len(turns)
    totals["omitted_turns"] = max(0, len(turns) - last_turns)
    return {
        "before_exclusive": before.isoformat() if before else None,
        "totals": dict(totals), "tokens": total_tokens,
        "turns": list(turns.values())[-last_turns:], "warnings": dict(issues),
        "notes": [
            "Usage totals use the first token_usage_record for each (turn_id, response_id); token_count is ignored.",
            "When session_meta.id exists, only usage records with that thread_id are included.",
            "Input includes cached and cache-write subsets; uncached = input - cached - cache-write. Output includes reasoning.",
            "Wall duration sums completed turns, includes waits, and is neither CPU time nor unique elapsed time for overlapping turns.",
            "Text characters are textual values excluding typed media, binary fields and data URIs; untyped opaque strings may remain. Characters are not tokens.",
            "Missing values are null; totals sum known values only. A completion record does not establish that the full session was captured.",
        ],
    }


def print_compact(summary):
    totals, tokens = summary["totals"], summary["tokens"]
    fmt = lambda value: "?" if value is None else f"{value:,}"
    print(f"Turns: {totals['turns']} | completed: {totals.get('completed_turns', 0)} | responses: {totals.get('responses', 0)}")
    print(f"Completed-turn wall time (includes waits): {totals.get('completed_turn_wall_ms', 0) / 1000:,.3f} s")
    print("Tokens: " + " | ".join(f"{name}={fmt(value)}" for name, value in tokens.items()))
    print(f"Tools: calls={totals.get('tool_calls', 0)} outputs={totals.get('tool_outputs', 0)} | text chars: calls={totals.get('tool_call_text_chars', 0):,} outputs={totals.get('tool_output_text_chars', 0):,}")
    print("Per turn: id | completed | wall ms | responses | input/cached/write/uncached/output/reasoning/total | calls/outputs | call/output chars")
    fields = (*TOKEN_FIELDS[:3], "uncached_input_tokens", *TOKEN_FIELDS[3:])
    for item in summary["turns"]:
        counts = "/".join(fmt(item["tokens"][field]) for field in fields)
        print(f"{item['turn_id']} | {'yes' if item['completed'] else 'no'} | {fmt(item['wall_duration_ms'])} | {item['responses']} | {counts} | {item['tool_calls']}/{item['tool_outputs']} | {item['tool_call_text_chars']:,}/{item['tool_output_text_chars']:,}")
    print(f"Earlier turns omitted from table: {totals['omitted_turns']} (included in totals)")
    print(f"Duplicate usage ignored: {totals.get('duplicate_usage_records_ignored', 0)} | token_count ignored: {totals.get('token_count_records_ignored', 0)}")
    if totals.get("usage_records_from_other_threads_excluded"):
        print(f"Other-thread usage records excluded: {totals['usage_records_from_other_threads_excluded']}")
    if summary["before_exclusive"]:
        print(f"Before (exclusive): {summary['before_exclusive']} | later records excluded: {totals.get('records_at_or_after_cutoff', 0)}")
    print("Warnings: " + (", ".join(f"{name}={value}" for name, value in summary["warnings"].items()) or "none detected"))
    for note in summary["notes"][1:]:
        print(note)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rollout", required=True, type=Path, help="One explicit JSONL path; no session discovery")
    parser.add_argument("--before", type=iso_time, help="Exclusive ISO timestamp with timezone")
    parser.add_argument("--last-turns", type=int, default=20, help="Last N turn rows, all turns remain in totals (default: 20)")
    parser.add_argument("--json", action="store_true", help="Print metadata JSON to stdout")
    args = parser.parse_args(argv)
    if args.last_turns < 1:
        parser.error("--last-turns must be positive")
    try:
        result = summarize(args.rollout, args.before, args.last_turns)
    except (OSError, UnicodeError):
        print("Unable to read the requested rollout file.", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    else:
        print_compact(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
