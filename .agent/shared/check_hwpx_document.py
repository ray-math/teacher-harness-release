"""Small TEMP-only installation smoke check; never opens user documents or Hancom."""
import hashlib
import json
from pathlib import Path
import tempfile
import time
import zipfile
from xml.etree import ElementTree as ET

from hwpx import HwpxDocument


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def structure(path):
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "Invalid ZIP member")
        section = ET.fromstring(archive.read("Contents/section0.xml"))
        geometry = [(node.tag, sorted(node.attrib.items())) for node in section.iter()
                    if node.tag.rsplit("}", 1)[-1] in
                    {"tbl", "tc", "cellAddr", "cellSpan", "cellSz", "cellMargin"}]
        return archive.read("Contents/header.xml"), geometry


def main():
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="teacher-hwpx-install-") as temporary:
        folder = Path(temporary)
        source, output = folder / "원본 양식.hwpx", folder / "작성 결과.hwpx"
        original = HwpxDocument.new()
        original.add_paragraph("설치 확인용 합성 문서")
        table = original.add_table(1, 2)
        table.set_cell_text(0, 0, "연구회명")
        table.set_cell_text(0, 1, "입력 전")
        original.save_to_path(str(source))
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        before = structure(source)
        edited = HwpxDocument.open(str(source))
        require(edited.tables.all[0].cell(0, 1).text == "입력 전", "Source read failed")
        edited.tables.all[0].set_cell_text(0, 1, "교사 연구회", preserve_format=True)
        edited.save_to_path(str(output))
        reopened = HwpxDocument.open(str(output))
        require(reopened.tables.all[0].cell(0, 1).text == "교사 연구회", "Saved value did not reopen")
        require(reopened.tables.all[0].cell(0, 0).text == "연구회명", "Adjacent label changed")
        require(any(p.text == "설치 확인용 합성 문서" for p in reopened.paragraphs), "Body changed")
        require(structure(output) == before, "Table geometry or style definitions changed")
        require(hashlib.sha256(source.read_bytes()).hexdigest() == source_hash, "Source changed")
    print(json.dumps({"ok": True, "checks": ["read", "fill-cell", "save", "reopen",
        "preserve-source-and-table-format"], "seconds": round(time.perf_counter() - started, 3),
        "temporaryFilesRemoved": True, "nativeHancomVerified": False}))


if __name__ == "__main__":
    main()
