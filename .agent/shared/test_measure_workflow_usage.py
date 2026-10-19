"""Synthetic rollout tests; fixtures exist only in the system temporary folder."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from measure_workflow_usage import main, summarize, text_chars


def record(kind, payload, timestamp="2026-10-01T12:00:00Z"):
    return {"type": kind, "timestamp": timestamp, "payload": payload}


def start(turn_id="t1", **kwargs):
    return record("event_msg", {"type": "task_started", "turn_id": turn_id}, **kwargs)


def usage(turn_id="t1", response_id="r1", **values):
    counters = dict(input_tokens=100, cached_input_tokens=40, cache_write_input_tokens=10,
                    output_tokens=20, reasoning_output_tokens=5, total_tokens=120)
    counters.update(values)
    return record("token_usage_record", {"turn_id": turn_id, "response_id": response_id, "usage": counters,
                                         "turn_token_usage": {"total_tokens": 999999}})


def complete(turn_id="t1", duration=4000):
    return record("event_msg", {"type": "task_complete", "turn_id": turn_id, "duration_ms": duration})


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="workflow-usage-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "synthetic.jsonl"

    def write(self, records):
        self.path.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")

    def test_response_identity_dedup_and_subsets(self):
        self.write([start(), usage(), usage(),
                    record("event_msg", {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 999999}}}),
                    complete(), complete(), start("t2"), usage("t2"), complete("t2", 1000)])
        result = summarize(self.path)
        self.assertEqual(result["tokens"]["total_tokens"], 240)
        self.assertEqual(result["tokens"]["input_tokens"], 200)
        self.assertEqual(result["tokens"]["uncached_input_tokens"], 100)
        self.assertEqual(result["tokens"]["output_tokens"], 40)
        self.assertEqual(result["tokens"]["reasoning_output_tokens"], 10)
        self.assertEqual(result["totals"]["responses"], 2)
        self.assertEqual(result["totals"]["completed_turn_wall_ms"], 5000)
        self.assertEqual(result["totals"]["duplicate_usage_records_ignored"], 1)
        self.assertEqual(result["totals"]["token_count_records_ignored"], 1)

    def test_incomplete_missing_and_invalid_usage_reported(self):
        self.write([start(), usage(cached_input_tokens=None), start("t2"), complete("t2", None),
                    usage("t3", response_id=None), usage("t4", cached_input_tokens=101)])
        result = summarize(self.path)
        self.assertIsNone(result["tokens"]["uncached_input_tokens"])
        self.assertEqual(result["tokens"]["input_tokens"], 200)
        warnings = result["warnings"]
        self.assertEqual(warnings["turns_without_completion_record"], 2)
        self.assertEqual(warnings["turns_without_usage_records"], 1)
        self.assertEqual(warnings["completed_turns_missing_valid_duration"], 1)
        self.assertEqual(warnings["responses_missing_cached_input_tokens"], 1)
        self.assertEqual(warnings["usage_records_excluded_missing_identity"], 1)
        self.assertEqual(warnings["responses_with_invalid_input_cache_subsets"], 1)

    def test_tool_counts_media_exclusion_and_late_output_turn(self):
        secret = "PRIVATE_SENTINEL"
        self.write([start(),
                    record("response_item", {"type": "function_call", "call_id": "c1", "arguments": '{"cmd":"abc"}'}),
                    record("response_item", {"type": "custom_tool_call", "call_id": "c2", "input": "xy"}),
                    start("t2"),
                    record("response_item", {"type": "function_call_output", "call_id": "c1", "output": [
                        {"type": "text", "text": "hello"}, {"type": "image", "data": secret * 1000},
                        {"type": "reasoning", "text": secret}]}),
                    record("response_item", {"type": "custom_tool_call_output", "call_id": "c2", "output": json.dumps({"content": [
                        {"type": "text", "text": "ok"}, {"type": "image_url", "image_url": secret}]})}),
                    record("response_item", {"type": "message", "content": [{"type": "output_text", "text": secret}]}),
                    record("response_item", {"type": "reasoning", "summary": [{"text": secret}]})])
        result = summarize(self.path)
        self.assertEqual(result["totals"]["tool_calls"], 2)
        self.assertEqual(result["totals"]["tool_outputs"], 2)
        self.assertEqual(result["totals"]["tool_call_text_chars"], 5)
        self.assertEqual(result["totals"]["tool_output_text_chars"], 7)
        self.assertEqual(result["turns"][0]["tool_outputs"], 2)
        self.assertNotIn(secret, json.dumps(result))
        self.assertEqual(text_chars({"base64": secret, "text": "visible"}), 7)
        self.assertEqual(text_chars("hello data:image/png;base64,AAAA"), 6)

    def test_before_is_exclusive_and_missing_timestamp_skipped(self):
        at_cutoff = usage(response_id="r2")
        at_cutoff["timestamp"] = "2026-10-01T13:00:00+01:00"
        earlier = usage()
        earlier["timestamp"] = "2026-10-01T11:59:59.999Z"
        missing_time = usage(response_id="r3")
        missing_time.pop("timestamp")
        self.write([earlier, at_cutoff, missing_time, complete()])
        result = summarize(self.path, "2026-10-01T12:00:00Z")
        self.assertEqual(result["totals"]["responses"], 1)
        self.assertFalse(result["turns"][0]["completed"])
        self.assertEqual(result["totals"]["records_at_or_after_cutoff"], 2)
        self.assertEqual(result["warnings"]["records_skipped_missing_or_invalid_timestamp"], 1)
        with self.assertRaises(ValueError):
            summarize(self.path, "2026-10-01T12:00:00")

    def test_table_limit_retains_totals_and_cli_never_writes(self):
        self.write([usage(f"t{i}") for i in range(23)])
        before = set(Path(self.temp.name).iterdir())
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["--rollout", str(self.path), "--json"]), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(len(result["turns"]), 20)
        self.assertEqual(result["totals"]["omitted_turns"], 3)
        self.assertEqual(result["totals"]["responses"], 23)
        self.assertEqual(result["tokens"]["total_tokens"], 23 * 120)
        self.assertEqual(before, set(Path(self.temp.name).iterdir()))

    def test_conflicts_and_truncated_final_line_are_explicit(self):
        self.write([usage(), usage(input_tokens=200), complete(), complete(duration=1)])
        with self.path.open("a", encoding="utf-8") as stream:
            stream.write('{"type":')
        result = summarize(self.path)
        self.assertEqual(result["tokens"]["input_tokens"], 100)
        self.assertEqual(result["totals"]["completed_turn_wall_ms"], 4000)
        self.assertEqual(result["warnings"]["conflicting_duplicate_usage_records_first_kept"], 1)
        self.assertEqual(result["warnings"]["conflicting_completion_records"], 1)
        self.assertEqual(result["warnings"]["invalid_json_records"], 1)

    def test_session_id_excludes_inherited_usage_from_other_threads(self):
        own = usage()
        own["payload"]["thread_id"] = "session1"
        inherited = usage("inherited")
        inherited["payload"]["thread_id"] = "other-session"
        self.write([record("session_meta", {"id": "session1"}), own, inherited, usage("unknown")])
        result = summarize(self.path)
        self.assertEqual(result["totals"]["responses"], 1)
        self.assertEqual(result["tokens"]["input_tokens"], 100)
        self.assertEqual(result["totals"]["usage_records_from_other_threads_excluded"], 1)
        self.assertEqual(result["warnings"]["usage_records_excluded_missing_thread_identity"], 1)


if __name__ == "__main__":
    unittest.main()
