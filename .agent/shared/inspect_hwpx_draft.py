"""Read a HWPX once: revision, editor coordinates, text and style references.

Run with the installed HWPX runtime. Coordinates are zero-based, per section,
and apply only to source_sha256. No document is changed. --output creates a NEW
JSON file; otherwise bounded JSON goes to stdout. Use next_offset to continue.
Default paragraphs are editable, outside tables, using paragraph_patch indices.
Use --paragraph-operation both --include-cell-paragraphs for full diagnostics.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
from paragraph_target_preflight import runtime


def styles(payload):
    """References only, not expanded style definitions or nested-table styles."""
    result = {}
    for key in ("paraPrIDRef", "styleIDRef", "charPrIDRef", "borderFillIDRef"):
        values = list(dict.fromkeys(re.findall(rb'\b' + key.encode() + rb'="([^"]*)"', payload)))
        if values:
            result[key] = [v.decode("utf-8") for v in values]
    return result


def inspect(source, *, offset=0, limit=800, max_text=1200, max_chars=100000,
            paragraph_operation="paragraph_patch", include_cell_paragraphs=False):
    if offset < 0 or not 1 <= limit <= 100000 or not 1 <= max_text <= 100000 or max_chars < 4000:
        raise ValueError("Invalid inspection limits.")
    if paragraph_operation not in ("paragraph_patch", "set_paragraph_text", "both"):
        raise ValueError("Invalid paragraph operation.")
    patch, body = runtime()  # Same pinned coordinate engines as edit preflight.
    from hwpx import table_patch as table
    from hwpx.opc.security import guard_zip_file, read_member

    source = Path(source).resolve(strict=True)
    snapshot = source.read_bytes()
    records = []
    sections = []
    omitted = dict(cell_paragraphs=0, containers_or_unsupported=0)
    unsupported_cells = 0
    with zipfile.ZipFile(io.BytesIO(snapshot)) as archive:
        guard_zip_file(archive)
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate HWPX package members.")
        section_names = sorted(n for n in names if re.fullmatch(r"Contents/section\d+\.xml", n))
        if not section_names:
            raise ValueError("No HWPX document sections.")
        for name in section_names:
            raw = read_member(archive, name)
            # Parse for well-formedness; all coordinates come from the editor.
            ET.fromstring(raw)
            sections.append(name)
            xml = raw.decode("utf-8")
            table_spans = table._iter_table_spans(raw)
            candidates = {}
            if paragraph_operation in ("paragraph_patch", "both"):
                candidates["paragraph_patch"] = [(s.index, s.payload, s.start) for s in patch._paragraph_spans(raw)]
            if paragraph_operation in ("set_paragraph_text", "both"):
                candidates["set_paragraph_text"] = [(i, xml[a:b].encode("utf-8"), len(xml[:a].encode("utf-8")))
                                                    for i, (a, b) in enumerate(body.direct_paragraph_spans(xml))]
            for operation, spans in candidates.items():
                for index, payload, position in spans:
                    edit = patch._text_edit_for_paragraph(payload, "")
                    block = payload.decode("utf-8")
                    editable = edit is not None and not body._TBL_RE.search(block) and len(
                        re.findall(r"<(?:[A-Za-z_][\w.-]*:)?p\b", block)) == 1
                    if not include_cell_paragraphs:
                        if any(a < position < b for a, b in table_spans):
                            omitted["cell_paragraphs"] += 1
                            continue
                        if not editable:
                            omitted["containers_or_unsupported"] += 1
                            continue
                    # Containers must never be offered as text replacement targets.
                    records.append(dict(kind="paragraph", operation=operation, section_path=name,
                                        paragraph_index=index, editable=bool(editable),
                                        before=edit[3] if editable else None,
                                        styles=styles(payload) if editable else {}))
            spans = table_spans
            for index, (start, end) in enumerate(spans):
                payload = raw[start:end]
                parents = [i for i, (a, b) in enumerate(spans[:index]) if a < start and end < b]
                records.append(dict(kind="table", section_path=name, table_index=index,
                                    parent_table_index=parents[-1] if parents else None,
                                    rows=table._iattr(payload, "tbl", "rowCnt"),
                                    cols=table._iattr(payload, "tbl", "colCnt")))
                for cell in table._direct_cells(payload):
                    cell_raw = payload[cell.start:cell.end]
                    direct = table._mask_nested_tables(cell_raw)
                    # Namespace declarations are inherited from the section.
                    paragraphs = [patch._text_edit_for_paragraph(m.group(), "")
                                  for m in table._P_SPAN_RE.finditer(direct)]
                    missing = sum(p is None for p in paragraphs)
                    text = "\n".join(p[3] if p is not None else "[unsupported paragraph: full read required]"
                                     for p in paragraphs)
                    record = dict(kind="cell", section_path=name, table_index=index,
                                        row=cell.row, col=cell.col, row_span=cell.row_span,
                                        col_span=cell.col_span, text=text, styles=styles(direct),
                                        contains_nested_table=bool(table._iter_table_spans(cell_raw)))
                    if missing:
                        record.update(text_complete=False, unsupported_paragraphs=missing, requires_full_read=True)
                        unsupported_cells += 1
                    records.append(record)
    counts = {kind: sum(r["kind"] == kind for r in records) for kind in ("paragraph", "table", "cell")}
    selected, used = [], 0
    for record in records[offset:offset + limit]:
        item = dict(record)
        for key in ("text", "before"):
            if isinstance(item.get(key), str) and len(item[key]) > max_text:
                item[key] = item[key][:max_text]
                item[key + "_truncated"] = True
        size = len(json.dumps(item, ensure_ascii=False))
        if selected and used + size > max_chars:
            break
        selected.append(item)
        used += size
    end = offset + len(selected)
    return dict(ok=True, source=str(source), source_sha256=hashlib.sha256(snapshot).hexdigest(),
                source_bytes=len(snapshot), sections=sections, counts=counts,
                paragraph_operation=paragraph_operation, include_cell_paragraphs=include_cell_paragraphs,
                omitted_paragraphs=omitted, unsupported_cells=unsupported_cells,
                scope_note="Default omits table-internal paragraphs and noneditable containers; cells carry table text. This is an editing map, not a complete document transcription. Unsupported cells require a fuller reader.",
                coordinate_note="Zero-based, per section. Use each paragraph's operation; table cells use fill_cells. Merged cells show their anchor and spans. Coordinates require this source hash. Truncated before text is not a target contract.",
                offset=offset, total_records=len(records), next_offset=end if end < len(records) else None,
                records=selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="Create a new JSON file; never overwrite.")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int, default=800)
    parser.add_argument("--max-text", type=int, default=1200)
    parser.add_argument("--max-chars", type=int, default=100000)
    parser.add_argument("--paragraph-operation", choices=("paragraph_patch", "set_paragraph_text", "both"), default="paragraph_patch")
    parser.add_argument("--include-cell-paragraphs", action="store_true", help="Include cell paragraphs and noneditable containers for diagnostics.")
    args = parser.parse_args()
    result = inspect(args.source, offset=args.offset, limit=args.limit,
                     max_text=args.max_text, max_chars=args.max_chars,
                     paragraph_operation=args.paragraph_operation,
                     include_cell_paragraphs=args.include_cell_paragraphs)
    if args.output:
        if args.output.suffix.lower() != ".json":
            raise ValueError("Inspection output must be a new .json file.")
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, ensure_ascii=False, separators=(",", ":"))
        print(json.dumps(dict(ok=True, output=str(args.output.resolve()), counts=result["counts"],
                              source_sha256=result["source_sha256"], next_offset=result["next_offset"])))
    else:
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    try:
        main()
    except Exception as error:
        print(json.dumps(dict(ok=False, error=str(error)), ensure_ascii=False))
        sys.exit(1)
