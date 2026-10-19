# Request configuration

Save `collection.json` directly in an active job. School, date, subject order, paths and roster coordinates belong here, not in the reusable runner. All live sources must match that job's intake hashes.

```json
{
  "base": "D:/.../selected-form.hwpx",
  "sources": ["D:/.../subject-A.hwpx", "D:/.../combined-subjects.hwpx"],
  "output": "wip/docs/취합 명단.hwpx",
  "subjects": ["과목A", "과목B"],
  "expectedCounts": {"과목A": 7},
  "subjectAliases": {"원본의 이전 표기": "과목A"},
  "headers": {"subject": "과목명", "teacher": "담당 교사", "criteria": "선정기준", "students": "미도달 예상 학생 명단"},
  "noneMarkers": ["없음"],
  "rosterPython": "C:/.../bundled/python/python.exe",
  "roster": {
    "path": "D:/.../명렬표.xlsx",
    "blocks": [{"sheet": "명렬표", "firstRow": 7, "lastRow": 26, "numberColumn": 1, "nameColumn": 2, "idBase": 1100}]
  }
}
```

Roster coordinates are one-based. Add blocks for side-by-side classes; use `idColumn` instead of `idBase` when IDs are already present. `idBase + number` must follow the actual school's observed convention, not an assumed national convention. The bundled Python needs read-only `openpyxl`; the HWPX runner uses the workspace's installed HWPX runtime. No spreadsheet authoring tool is loaded.

Supported student entries contain a 4–6 digit ID and a 2–5 syllable Korean name, or a name without an ID. Other formats stop for bounded adaptation. Tables must have one header row and the named fields. This is a tested family of collection tasks, not a universal parser for every school document.
