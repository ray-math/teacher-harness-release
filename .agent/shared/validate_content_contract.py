"""Read-only saved-content assertions. Standard library only; never edits documents."""
import argparse
import hashlib
import json
import re
import sys
import zipfile
from datetime import datetime, timezone, timedelta
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path
from xml.etree import ElementTree as ET


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    def unique(pairs):
        out = {}
        for key, value in pairs:
            if key in out:
                raise ValueError("Duplicate JSON key: " + key)
            out[key] = value
        return out
    return json.loads(Path(path).read_text(encoding="utf-8-sig"), object_pairs_hook=unique)


def local(tag):
    return tag.rsplit("}", 1)[-1]


def text_of(node, odt=False):
    if odt:
        def walk(n):
            tag = local(n.tag)
            if tag == "s":
                return " " * int(n.get("{urn:oasis:names:tc:opendocument:xmlns:text:1.0}c", "1"))
            if tag in ("tab", "line-break"):
                return "\t" if tag == "tab" else "\n"
            return (n.text or "") + "".join(walk(c) + (c.tail or "") for c in n)
        return walk(node)
    def walk(n):
        tag = local(n.tag)
        if tag == "t":
            for child in n:
                if local(child.tag) not in ("tab", "lineBreak", "nbSpace", "fwSpace") or len(child):
                    raise ValueError("Unsupported HWPX text control: " + local(child.tag))
            return (n.text or "") + "".join(walk(c) + (c.tail or "") for c in n)
        if tag in ("nbSpace", "fwSpace"):
            return "\u00a0" if tag == "nbSpace" else "\u3000"
        if tag in ("tab", "lineBreak"):
            return "\t" if tag == "tab" else "\n"
        return "".join(walk(c) for c in n)
    return walk(node)


def document(path):
    """Return explicit 0-based paragraph/cell locators and a document text scope."""
    records = []
    with zipfile.ZipFile(path) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("Duplicate package members")
        odt = path.suffix.lower() == ".odt"
        if odt:
            names = ["content.xml"]
        elif path.suffix.lower() == ".hwpx":
            names = sorted((n for n in archive.namelist() if re.fullmatch(r"Contents/section\d+\.xml", n)), key=lambda n: int(re.search(r"(\d+)\.xml", n)[1]))
        else:
            raise ValueError("Only saved HWPX and ODT outputs are supported")
        if not names:
            raise ValueError("No document sections")
        paragraphs = []
        def hwpx_stream(node):
            tag = local(node.tag)
            if tag in ("t", "tab", "lineBreak", "nbSpace", "fwSpace"):
                return text_of(node)
            inner = "".join(hwpx_stream(child) for child in node)
            return "\n" + inner + "\n" if tag == "p" else inner
        for section, name in enumerate(names):
            root = ET.fromstring(archive.read(name))
            if not odt:
                paragraphs.append(hwpx_stream(root).strip("\n"))
            prefix = {} if odt else {"section": section}
            ps = [n for n in root.iter() if local(n.tag) in (("p", "h") if odt else ("p",))]
            for i, node in enumerate(ps):
                value = text_of(node, odt)
                if odt:
                    paragraphs.append(value)
                records.append({"locator": {"kind": "paragraph", **prefix, "index": i}, "text": value})
            tables = [n for n in root.iter() if local(n.tag) == ("table" if odt else "tbl")]
            for ti, table in enumerate(tables):
                if odt:
                    tn = "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}"
                    # Nested tables have their own table index, not parent rows.
                    def rows(n):
                        for child in n:
                            if local(child.tag) == "table-row":
                                yield child
                            elif local(child.tag) in ("table-header-rows", "table-rows", "table-row-group"):
                                yield from rows(child)
                    ri = 0
                    for row in rows(table):
                        repeat_rows = int(row.get(tn + "number-rows-repeated", "1"))
                        if repeat_rows > 10000:
                            raise ValueError("Unbounded repeated table rows")
                        for _ in range(repeat_rows):
                            ci = 0
                            for cell in row:
                                if local(cell.tag) not in ("table-cell", "covered-table-cell"):
                                    continue
                                repeat = int(cell.get(tn + "number-columns-repeated", "1"))
                                if repeat > 10000:
                                    raise ValueError("Unbounded repeated table cells")
                                value = "\n".join(text_of(p, True) for p in cell.iter() if local(p.tag) in ("p", "h"))
                                for _ in range(repeat):
                                    records.append({"locator": {"kind": "cell", "table": ti, "row": ri, "col": ci}, "text": value})
                                    ci += 1
                            ri += 1
                else:
                    for row in table:
                        if local(row.tag) != "tr":
                            continue
                        for cell in row:
                            if local(cell.tag) != "tc":
                                continue
                            addr = next((c for c in cell if local(c.tag) == "cellAddr"), None)
                            if addr is None:
                                raise ValueError("HWPX cell has no cellAddr")
                            value = hwpx_stream(cell).strip("\n")
                            records.append({"locator": {"kind": "cell", **prefix, "table": ti, "row": int(addr.get("rowAddr")), "col": int(addr.get("colAddr"))}, "text": value})
        records.insert(0, {"locator": {"kind": "document"}, "text": "\n".join(paragraphs)})
    return records


def xlsx_value(path, sheet, address):
    if not re.fullmatch(r"[A-Z]+[1-9]\d*", address):
        raise ValueError("Use one explicit uppercase Excel cell address")
    ns = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    rel_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    with zipfile.ZipFile(path) as z:
        book = ET.fromstring(z.read("xl/workbook.xml"))
        sheets = [s for s in book.findall("s:sheets/s:sheet", ns) if s.get("name") == sheet]
        if len(sheets) != 1:
            raise ValueError("Excel sheet did not match exactly once")
        rid = sheets[0].get("{" + rel_ns + "}id")
        rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
        rel = [r for r in rels if r.get("Id") == rid and r.get("TargetMode") != "External"]
        if len(rel) != 1:
            raise ValueError("Excel worksheet relationship missing")
        import posixpath
        target = rel[0].get("Target")
        member = target.lstrip("/") if target.startswith("/") else posixpath.normpath("xl/" + target)
        root = ET.fromstring(z.read(member))
        cells = [c for c in root.findall(".//s:sheetData/s:row/s:c", ns) if c.get("r") == address]
        if len(cells) > 1:
            raise ValueError("Duplicate Excel cell")
        if not cells:
            # An omitted cell is blank in a successfully resolved worksheet.
            return ""
        c = cells[0]
        if c.find("s:f", ns) is not None:
            raise ValueError("Formula source needs a model-confirmed explicit expected value and evidence; cached results are not recalculated")
        typ = c.get("t")
        if typ == "inlineStr":
            return "".join(t.text or "" for t in c.findall(".//s:t", ns))
        v = c.find("s:v", ns)
        value = "" if v is None else (v.text or "")
        if typ == "s":
            shared = ET.fromstring(z.read("xl/sharedStrings.xml"))
            return "".join(t.text or "" for t in shared[int(value)].findall(".//s:t", ns))
        if typ == "e":
            raise ValueError("Excel source is an error cell")
        return value


def source_value(ref, sources, source_docs):
    """Read one explicit source location without accepting mixed reference formats."""
    if not isinstance(ref, dict) or not isinstance(ref.get("source"), str) or ref["source"] not in sources:
        raise ValueError("sourceRef must name a hashed source")
    path = sources[ref["source"]]["resolved"]
    if "locator" not in ref:
        if set(ref) != {"source", "sheet", "cell"} or path.suffix.lower() != ".xlsx":
            raise ValueError("Excel sourceRef requires only source, sheet and cell on an XLSX source")
        if not isinstance(ref["sheet"], str) or not isinstance(ref["cell"], str):
            raise ValueError("Excel sourceRef sheet and cell must be strings")
        value = xlsx_value(path, ref["sheet"], ref["cell"])
    else:
        if set(ref) != {"source", "locator"} or path.suffix.lower() not in (".hwpx", ".odt"):
            raise ValueError("Document sourceRef requires only source and locator on an HWPX or ODT source")
        locator = ref["locator"]
        if not isinstance(locator, dict):
            raise ValueError("Document source locator must be an explicit object")
        kind = locator.get("kind")
        fields = {"document": {"kind"}, "paragraph": {"kind", "index"},
                  "cell": {"kind", "table", "row", "col"}}
        if not isinstance(kind, str) or kind not in fields:
            raise ValueError("Unsupported document source locator kind")
        required = fields[kind].copy()
        if path.suffix.lower() == ".hwpx" and kind != "document":
            required.add("section")
        if set(locator) != required or any(type(locator[key]) is not int or locator[key] < 0 for key in required - {"kind"}):
            raise ValueError("Document source locator must contain the exact nonnegative integer coordinates")
        if path not in source_docs:
            source_docs[path] = document(path)
        matches = [r["text"] for r in source_docs[path] if r["locator"] == locator]
        if len(matches) != 1:
            raise ValueError("Document source locator must match exactly once")
        value = matches[0]
    if value == "":
        raise ValueError("Source location is blank; use an explicit blank assertion after model review")
    return value


def normalize(value, operations):
    for op in operations:
        if op == "trim":
            value = value.strip()
        elif op == "line_endings":
            value = value.replace("\r\n", "\n").replace("\r", "\n")
        elif op == "collapse_whitespace":
            value = re.sub(r"\s+", " ", value)
        elif op == "number":
            value = decimal_text(number(value))
        elif op == "date":
            match = re.fullmatch(r"\s*(\d{4})\s*[.\-/년]\s*(\d{1,2})\s*[.\-/월]\s*(\d{1,2})\s*[.일]?\s*", value)
            if not match:
                raise ValueError("Expected one explicit calendar date: " + value)
            value = datetime(*map(int, match.groups())).date().isoformat()
        else:
            raise ValueError("Unknown normalize operation: " + str(op))
    return value


def number(value):
    """One number only; never silently join digits from prose or equations."""
    if not isinstance(value, str) or len(value) > 200:
        raise ValueError("Numeric value must be bounded text")
    match = re.fullmatch(r"\s*[₩￦]?\s*([+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)\s*(?:원|%|명|시간|개)?\s*", value)
    if not match:
        raise ValueError("Expected one numeric value: " + value)
    result = Decimal(match[1].replace(",", ""))
    if not result.is_finite():
        raise ValueError("Non-finite numeric value")
    return result


def decimal_text(value):
    text = format(value, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def extract_text(value, pattern, group):
    if not isinstance(pattern, str) or len(pattern) > 500 or type(group) is not int or group < 0:
        raise ValueError("Invalid extract pattern/group")
    matches = list(re.finditer(pattern, value))
    if len(matches) != 1:
        raise ValueError("extract must match exactly once")
    selected = matches[0].group(group)
    if selected is None or selected == "":
        raise ValueError("extract must select nonempty text")
    return selected


def expression_value(expr, sources, source_docs, docs, depth=0):
    """Bounded declarative calculation; no code execution or spreadsheet cache."""
    if depth > 20 or not isinstance(expr, dict):
        raise ValueError("Invalid or overly nested expectedExpr")
    if set(expr) == {"sourceRef"}:
        return source_value(expr["sourceRef"], sources, source_docs)
    if set(expr) == {"literal"}:
        value = expr["literal"]
        if not isinstance(value, str) or len(value) > 10000:
            raise ValueError("Expression literal must be bounded text")
        return value
    if set(expr) == {"outputRef"}:
        ref = expr["outputRef"]
        if not isinstance(ref, dict) or set(ref) != {"output", "locator"} or ref["output"] not in docs:
            raise ValueError("outputRef requires output and locator")
        values = [r["text"] for r in docs[ref["output"]] if r["locator"] == ref["locator"]]
        if len(values) != 1:
            raise ValueError("outputRef must match exactly once")
        return values[0]
    op = expr.get("op")
    if op in ("sum", "product") and set(expr) == {"op", "args"}:
        args = expr["args"]
        if not isinstance(args, list) or not 1 <= len(args) <= 1000:
            raise ValueError("sum/product requires 1..1000 arguments")
        with localcontext() as context:
            context.prec = 100
            result = Decimal(0 if op == "sum" else 1)
            for arg in args:
                value = number(expression_value(arg, sources, source_docs, docs, depth + 1))
                result = result + value if op == "sum" else result * value
            return decimal_text(result)
    if op == "extract" and set(expr) == {"op", "arg", "pattern", "group"}:
        value = expression_value(expr["arg"], sources, source_docs, docs, depth + 1)
        return extract_text(value, expr["pattern"], expr["group"])
    if op == "excel_date" and set(expr) == {"op", "arg"}:
        serial = number(expression_value(expr["arg"], sources, source_docs, docs, depth + 1))
        if serial != serial.to_integral_value() or not 61 <= serial <= 2958465:
            raise ValueError("excel_date requires a valid integral 1900-system serial after 1900-03-01")
        return (datetime(1899, 12, 30) + timedelta(days=int(serial))).date().isoformat()
    raise ValueError("Unsupported expectedExpr shape or operation")


def required_profile(job, inputs, contract, sources, outputs):
    binding = inputs.get("requiredContentProfile")
    if binding is None:
        if "requiredProfile" in contract:
            raise ValueError("requiredProfile must be bound by intake inputs")
        return {}, None
    if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
        raise ValueError("Invalid requiredContentProfile binding")
    if contract.get("requiredProfile") != binding:
        raise ValueError("Required profile omitted or changed in content contract")
    path = Path(binding["path"])
    path = (job / path).resolve() if not path.is_absolute() else path.resolve()
    sha = digest(path)
    if not re.fullmatch(r"[a-fA-F0-9]{64}", binding.get("sha256", "")) or sha != binding["sha256"].lower():
        raise ValueError("Required profile hash changed")
    profile = read_json(path)
    if profile.get("schemaVersion") != "content-required-profile/v1":
        raise ValueError("Unsupported required profile schema")
    hashes = profile.get("sourceHashes")
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError("Required profile needs sourceHashes")
    for ident, expected in hashes.items():
        if not isinstance(expected, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", expected):
            raise ValueError("Invalid required source hash: " + ident)
        if ident not in sources or sources[ident].get("sha256", "").lower() != expected.lower():
            raise ValueError("Required profile source missing or changed: " + ident)
    required_outputs = profile.get("requiredOutputs")
    if not isinstance(required_outputs, list) or not required_outputs or len(set(required_outputs)) != len(required_outputs):
        raise ValueError("Required profile needs distinct requiredOutputs")
    if not set(required_outputs).issubset(outputs):
        raise ValueError("Required profile output missing")
    assertions = keyed(profile.get("assertions"), "required assertions")
    return assertions, {"path": str(path), "sha256": sha, "assertionIds": list(assertions)}


def keyed(items, label, allow_empty=False):
    if not isinstance(items, list) or (not items and not allow_empty):
        raise ValueError(label + " must be a nonempty array")
    out = {}
    for item in items:
        ident = item.get("id")
        if not isinstance(ident, str) or not ident.strip() or ident in out:
            raise ValueError("Missing or duplicate " + label + " id")
        out[ident] = item
    return out


def validate(job):
    job = job.resolve()
    contract_path = job / "content-contract.json"
    contract_sha = digest(contract_path)
    contract = read_json(contract_path)
    if contract.get("schemaVersion") != "content-contract/v1":
        raise ValueError("Unsupported content contract schema")
    inputs = read_json(job / "inputs.json")
    cycle = inputs.get("deliveryCycle", {})
    if not cycle.get("id") or not cycle.get("requestKey"):
        raise ValueError("Content validation needs current intake delivery cycle")
    sources = keyed(contract.get("sources", []), "sources", allow_empty=True)
    outputs = keyed(contract.get("outputs"), "outputs")
    required, profile_record = required_profile(job, inputs, contract, sources, outputs)
    assertions = keyed(contract.get("assertions", []), "assertions", allow_empty=bool(required))
    for ident, assertion in required.items():
        if ident in assertions and assertions[ident] != assertion:
            raise ValueError("Required assertion cannot be overridden: " + ident)
        assertions[ident] = assertion
    source_records, output_records, results, docs, source_docs = [], [], [], {}, {}
    for ident, source in sources.items():
        path = Path(source["path"])
        path = (job / path).resolve() if not path.is_absolute() else path.resolve()
        sha = digest(path)
        if not re.fullmatch("[a-fA-F0-9]{64}", source.get("sha256", "")) or sha != source["sha256"].lower():
            raise ValueError("Source hash changed or missing: " + ident)
        source_records.append({"id": ident, "path": str(path), "sha256": sha})
        source["resolved"] = path
    paths, targets = set(), set()
    for ident, output in outputs.items():
        path = (job / output["path"]).resolve()
        if not any(path.is_relative_to(job / "wip" / folder) for folder in ("docs", "carry")):
            raise ValueError("Output must stay inside job wip/docs or wip/carry")
        target = output.get("targetRelativePath", "").replace("\\", "/")
        if not target or Path(target).is_absolute() or ".." in target.split("/"):
            raise ValueError("Invalid targetRelativePath")
        if str(path).lower() in paths or target.lower() in targets:
            raise ValueError("Duplicate output path or target")
        paths.add(str(path).lower()); targets.add(target.lower())
        sha = digest(path)
        docs[ident] = document(path)
        output_records.append({"id": ident, "path": str(path), "targetRelativePath": target, "sha256": sha})
    covered = set()
    for ident, assertion in assertions.items():
        output = assertion.get("output")
        if output not in outputs:
            raise ValueError("Unknown assertion output: " + ident)
        covered.add(output)
        locator = assertion.get("locator")
        matches = [r["text"] for r in docs[output] if r["locator"] == locator]
        if len(matches) != 1:
            raise ValueError("Locator must match exactly once: " + ident)
        operations = assertion.get("normalize", [])
        if not isinstance(operations, list):
            raise ValueError("normalize must be an explicit array")
        actual = matches[0]
        if "actualExtract" in assertion:
            extract = assertion["actualExtract"]
            if not isinstance(extract, dict) or set(extract) != {"pattern", "group"}:
                raise ValueError("actualExtract requires pattern and group")
            actual = extract_text(actual, extract["pattern"], extract["group"])
        actual = normalize(actual, operations)
        op = assertion.get("op")
        if op not in ("exact", "contains", "absent", "blank"):
            raise ValueError("Unsupported assertion operation: " + ident)
        for evidence in assertion.get("evidence", []):
            if evidence.get("source") not in sources or not evidence.get("location"):
                raise ValueError("Evidence must name a hashed source and location: " + ident)
        if op == "blank":
            if any(k in assertion for k in ("expected", "sourceRef", "expectedExpr")):
                raise ValueError("blank does not accept expected/sourceRef")
            expected = ""
        else:
            if sum(k in assertion for k in ("expected", "sourceRef", "expectedExpr")) != 1:
                raise ValueError("Use exactly one expected, sourceRef or expectedExpr: " + ident)
            if "sourceRef" in assertion:
                expected = source_value(assertion["sourceRef"], sources, source_docs)
            elif "expectedExpr" in assertion:
                expected = expression_value(assertion["expectedExpr"], sources, source_docs, docs)
            else:
                expected = assertion["expected"]
                if not isinstance(expected, str):
                    raise ValueError("expected must be a string: " + ident)
                if op in ("exact", "contains") and not assertion.get("evidence") and not str(assertion.get("reason", "")).strip():
                    raise ValueError("Explicit expected needs evidence or a model decision reason: " + ident)
            expected = normalize(expected, operations)
            if op in ("contains", "absent") and not expected:
                raise ValueError("Empty contains/absent expected is not an assertion")
        ok = (actual == expected) if op in ("exact", "blank") else ((expected in actual) if op == "contains" else (expected not in actual))
        results.append({"id": ident, "output": output, "locator": locator, "op": op, "normalize": operations, "ok": ok,
                        "actualSha256": hashlib.sha256(actual.encode()).hexdigest(), "expectedSha256": hashlib.sha256(expected.encode()).hexdigest()})
        if not ok:
            results[-1].update(actual=actual, expected=expected)
    if covered != set(outputs):
        raise ValueError("Every output must have at least one assertion")
    # Detect concurrent writes during extraction as well as changed saved receipts.
    for record in source_records + output_records:
        if digest(record["path"]) != record["sha256"]:
            raise ValueError("File changed during validation")
    if digest(contract_path) != contract_sha:
        raise ValueError("Contract changed during validation")
    if profile_record and digest(profile_record["path"]) != profile_record["sha256"]:
        raise ValueError("Required profile changed during validation")
    result = {"schemaVersion": "content-validation/v1", "ok": all(r["ok"] for r in results), "jobPath": str(job),
            "deliveryCycleId": cycle["id"], "requestKey": cycle["requestKey"], "contractPath": str(contract_path),
            "contractSha256": contract_sha, "sources": source_records, "outputs": output_records,
            "assertions": results, "verification": "saved-content-only; not visual; semantic mapping and assertion coverage are model responsibilities"}
    if profile_record:
        result["requiredProfile"] = profile_record
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", type=Path)
    parser.add_argument("--inspect", type=Path)
    parser.add_argument("--inspect-output", type=Path)
    parser.add_argument("--check-existing", action="store_true")
    args = parser.parse_args()
    if args.inspect:
        rendered = json.dumps(document(args.inspect), ensure_ascii=False, indent=2)
        if args.inspect_output:
            args.inspect_output.write_text(rendered, encoding="utf-8")
            print(json.dumps({"ok": True, "inspectionPath": str(args.inspect_output)}))
        else:
            print(rendered)
        return 0
    if not args.job:
        parser.error("--job is required")
    receipt_path = args.job / "wip/receipts/content-validation.json"
    try:
        current = validate(args.job)
        if args.check_existing:
            previous = read_json(receipt_path)
            previous.pop("checkedAt", None)
            if previous != current or not current["ok"]:
                raise ValueError("Content validation receipt is stale, changed, or failed; revalidate")
        else:
            current["checkedAt"] = datetime.now(timezone.utc).isoformat()
            receipt_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = receipt_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(current, ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(receipt_path)
        failed = [a["id"] for a in current["assertions"] if not a["ok"]]
        print(json.dumps({"ok": current["ok"], "receiptPath": str(receipt_path), "assertionCount": len(current["assertions"]), "failedAssertions": failed}))
        return 0 if current["ok"] else 1
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError, zipfile.BadZipFile, IndexError, InvalidOperation, re.error, OverflowError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
