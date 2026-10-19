# 공통 시험 기록 모드

기존 업무에 `commonRecord.enabled=true`가 설정된 경우에만 읽는다. 일반 업무나 새 학년도 업무에 이 모드를 자동 적용하지 않는다. 보고 내용은 [콘솔 보고](console-report.md), 실행 코드 변경은 유지보수 스킬의 범위다.

When `.ai/work.json.commonRecord.enabled` is true, the generator uses `.ai/exam-record.json` (schema `exam-workspace/v1`) and `.ai/exam-system/template.html` to render the same `업무현황.html`. This opt-in replaces that work's legacy browser-only checklist; default work consoles are unchanged. Do not regenerate from a stale seed or edit production HTML directly.

Semester subjects, students, teachers and operating decisions are shared once. Exam-specific applicability, slots, paper metadata, tasks and documents stay under each exam. New exams reset dates, applicability, evidence, submission, review and distribution state. Fixed `commonSnapshot` exam baselines retain their historical population when semester records change.

Browser edits persist atomically to the selected folder's canonical JSON after checking the previous content, with a dated `exam-record_fixNN_YYYYMMDD-HHmmss.json` copy beside it in `.ai`. Never create `previous_versions`. These internal records stay hidden; document revision storage follows [the storage policy](storage.md), with exact `revisionHistory` paths retained for existing and new records. A browser permission prompt remains a user action. A disconnected page is a labeled generated snapshot, not proof of current disk state. Legacy checkbox values remain in their original localStorage key and are viewable as historical marks, never automatic completion evidence.

For AI follow-up, read the current canonical record and exact source files; retain its current revision and unknown values. Save a previous version, increment revision, append history, and regenerate with `Update-HumanWorkConsole.ps1`. Never overwrite current human records with `initial-source-audit.json` or an old build. Completion evidence, data fingerprints and source-file hashes have different roles. File presence, intake, review or generation do not prove school approval, notice delivery, exam execution or NEIS storage.

The `subjects` dependency scope covers course identity/applicability/time links; `papers` covers question counts, points, pages, copies, receipts and review errors. Do not make routine paper receipt edits invalidate all earlier planning. `subject:<id>` tracks that subject and its linked enrollment/teacher/time. Misconfigured references, missing evidence and stale prerequisites are visible. Non-exam subject tasks do not block the exam's applicable work.

The native opener also accepts XLSM, ODT and MP3 documents after this update, through the same manifest validation. It does not change Office macros, browser settings, protocols or security policy.
