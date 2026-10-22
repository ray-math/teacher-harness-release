"""Read-only checks against the installed editor's paragraph coordinates.

XML-tree paragraph indexes are NOT editor indexes. Inspection lists candidates;
the caller must explicitly select the intended original text in a contract.
"""
from __future__ import annotations

import argparse
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import re
import sys
import zipfile

OPERATIONS = ("paragraph_patch", "set_paragraph_text")


def read_contract(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key in paragraph targets: " + key)
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding="utf-8-sig"), object_pairs_hook=unique)


def runtime():
    if version("python-hwpx") != "6.3.0" or version("python-hwpx-automation") != "7.0.4":
        raise ValueError("Unsupported paragraph preflight runtime; expected python-hwpx 6.3.0 / automation 7.0.4.")
    from hwpx import patch, body_patch
    for owner, name in ((patch, "_paragraph_spans"), (patch, "_text_edit_for_paragraph"),
                        (body_patch, "direct_paragraph_spans"), (body_patch, "_TBL_RE")):
        if not hasattr(owner, name):
            raise ValueError("Unsupported paragraph runtime API: " + name)
    if body_patch._text_edit_for_paragraph is not patch._text_edit_for_paragraph:
        raise ValueError("Unsupported paragraph runtime text extractor.")
    return patch, body_patch


def paragraph_records(source, operation):
    if operation not in OPERATIONS:
        raise ValueError("Unsupported paragraph operation: " + str(operation))
    patch, body = runtime()
    records = []
    with zipfile.ZipFile(source) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("Duplicate HWPX package members.")
        names = sorted(n for n in archive.namelist() if re.fullmatch(r"Contents/section\d+\.xml", n))
        if not names:
            raise ValueError("No HWPX document sections.")
        for name in names:
            raw = archive.read(name)
            if operation == "paragraph_patch":
                spans = [(s.index, s.payload) for s in patch._paragraph_spans(raw)]
            else:
                xml = raw.decode("utf-8")
                spans = [(i, xml[a:b].encode("utf-8")) for i, (a, b) in enumerate(body.direct_paragraph_spans(xml))]
            for index, payload in spans:
                edit = patch._text_edit_for_paragraph(payload, "")
                editable = edit is not None
                # A regex span can stop at a nested cell paragraph's close tag.
                # Never replace that partial table/container span.
                block = payload.decode("utf-8")
                if body._TBL_RE.search(block) or len(re.findall(r"<(?:[A-Za-z_][\w.-]*:)?p\b", block)) != 1:
                    editable = False
                records.append(dict(section_path=name, paragraph_index=index,
                                    before=edit[3] if edit is not None else None, editable=editable))
    return records


def plan_targets(plan):
    """Reject pre-target mutations rather than assume source coordinates survive."""
    targets, prior_mutation = [], False
    for step in plan.get("steps", []):
        op, args = step["op"], step.get("args", {})
        if op == "paragraph_patch":
            operations = [(op, p) for p in args.get("patches", [])]
        elif op == "apply_body_ops":
            operations = [(p.get("op"), p) for p in args.get("ops", [])]
        else:
            operations = [(op, args)]
        for operation, item in operations:
            if operation not in OPERATIONS:
                prior_mutation = True
                continue
            if prior_mutation:
                raise ValueError("Paragraph targets follow another mutation. Put paragraph edits first or split into separately inspected stages.")
            section = item.get("section_path") or item.get("sectionPath") or "Contents/section0.xml"
            index = item.get("index") if operation == "set_paragraph_text" else item.get("paragraph_index", item.get("paragraphIndex"))
            if not isinstance(section, str) or not re.fullmatch(r"Contents/section\d+\.xml", section):
                raise ValueError("Paragraph target requires a Contents/sectionN.xml section.")
            if type(index) is not int or index < 0:
                raise ValueError("Paragraph target index must be a nonnegative integer.")
            targets.append((operation, section, index))
    if len({t[0] for t in targets}) > 1:
        raise ValueError("Mixed paragraph coordinate engines require separately inspected plans.")
    if len(targets) != len(set(targets)):
        raise ValueError("Duplicate paragraph edit target; use one replacement per source paragraph.")
    return targets


def validate(source, plan, contract, expected_sha256, *, required):
    # Do not impose the new contract on unrelated/legacy editing operations.
    has_targets = any(s.get("op") == "paragraph_patch" or
                      (s.get("op") == "apply_body_ops" and any(o.get("op") == "set_paragraph_text"
                       for o in s.get("args", {}).get("ops", []))) for s in plan.get("steps", []))
    if not required and contract is None:
        return {"status": "not_required"}
    if not has_targets and contract is None:
        return {"status": "not_applicable"}
    targets = plan_targets(plan)
    if contract is None:
        raise ValueError("ParagraphTargetsPath is required for paragraph edits in a RequireContentValidation job.")
    if not isinstance(contract, dict) or set(contract) != {"source_sha256", "targets"}:
        raise ValueError("Paragraph contract requires exactly source_sha256 and targets.")
    revision = contract["source_sha256"]
    actual = hashlib.sha256(Path(source).read_bytes()).hexdigest()
    if not isinstance(revision, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", revision):
        raise ValueError("Invalid paragraph contract source_sha256.")
    if revision.lower() != expected_sha256.lower() or revision.lower() != actual:
        raise ValueError("Paragraph contract source SHA256 mismatch.")
    if not isinstance(contract["targets"], list):
        raise ValueError("Paragraph contract targets must be an array.")
    selected = {}
    for item in contract["targets"]:
        if not isinstance(item, dict) or set(item) != {"section_path", "paragraph_index", "before"}:
            raise ValueError("Each paragraph target requires exactly section_path, paragraph_index, before.")
        if not isinstance(item["section_path"], str) or type(item["paragraph_index"]) is not int or item["paragraph_index"] < 0 or not isinstance(item["before"], str):
            raise ValueError("Invalid paragraph target field types.")
        key = (item["section_path"], item["paragraph_index"])
        if key in selected:
            raise ValueError("Duplicate paragraph contract target.")
        selected[key] = item["before"]
    expected = {(section, index) for _, section, index in targets}
    if set(selected) != expected:
        raise ValueError("Paragraph contract has missing or extra targets.")
    if not targets:
        return {"status": "not_applicable"}
    records = {(r["section_path"], r["paragraph_index"]): r for r in paragraph_records(source, targets[0][0])}
    for key, before in selected.items():
        record = records.get(key)
        if record is None or not record["editable"]:
            raise ValueError(f"Paragraph target is unavailable to {targets[0][0]}: {key}")
        if before != record["before"]:
            # Do not put school-document content into common/log error text.
            raise ValueError(f"Paragraph before mismatch at {key}; inspect the selected editor operation's coordinates.")
    return {"status": "passed", "operation": targets[0][0], "targetCount": len(targets),
            "sourceSha256": actual}


def validate_job(job, source, plan, contract, expected_sha256):
    inputs = read_contract(Path(job) / "inputs.json")
    required = bool(inputs.get("requireContentValidation") or
                    (inputs.get("deliveryCycle") or {}).get("requireContentValidation"))
    return validate(source, plan, contract, expected_sha256, required=required)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inspect", required=True, type=Path)
    parser.add_argument("--operation", required=True, choices=OPERATIONS)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    before = hashlib.sha256(args.inspect.read_bytes()).hexdigest()
    records = paragraph_records(args.inspect, args.operation)
    if hashlib.sha256(args.inspect.read_bytes()).hexdigest() != before:
        raise ValueError("Source changed during paragraph inspection.")
    result = dict(source_sha256=before, operation=args.operation, candidates=records,
                  selectionRequired=True)
    serialized = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        # Never overwrite a source, human selection, or existing inspection.
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(serialized)
    else:
        print(serialized)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        sys.exit(1)
