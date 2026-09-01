-- 009_correct_pilot_data.sql
-- Replaces the [FILL] placeholder values seeded by 007 with the real data for
-- SOP-001 (Project Request Framework).
-- Depends on: 007
--
-- Written as UPDATE statements rather than edits to 007, because 007 has already
-- been applied. Handbook rule 3: never edit an applied migration.
--
-- All rows are located by business code, never by id.

BEGIN;

-- ---------------------------------------------------------------------------
-- Roles
--
-- R-003 was seeded as a placeholder cross-BU approver. It becomes Project
-- Manager, which is the first approver on this SOP.
--
-- R-002 (EVP of Operations) is left in place. It is a real role and will be
-- needed by other documents, it simply does not approve this one.
-- ---------------------------------------------------------------------------
UPDATE role
SET    name                   = 'Project Manager',
       role_type              = 'PMO Role',
       purpose                = 'Drafts and maintains PMO procedures; performs first-line review of procedure changes.',
       responsibility_summary = 'Reviews procedure content for accuracy against how the work is actually performed.',
       approval_authority     = 'First approver on PMO procedure changes.',
       updated_at             = now()
WHERE  role_code = 'R-003';

-- ---------------------------------------------------------------------------
-- Process
-- ---------------------------------------------------------------------------
UPDATE process
SET    name       = 'New Project Intake',
       purpose    = 'Capture project requests and preliminary project information.',
       updated_at = now()
WHERE  process_code = 'PROC-001';

-- ---------------------------------------------------------------------------
-- SOP-001
--
-- next_review_date is set to 2025-07-10: twelve months after the last genuine
-- review. That date has passed. This is deliberate and correct — the document IS
-- overdue, and recording a comfortable future date would hide the single most
-- useful fact the pilot surfaced.
--
-- status stays ACTIVE. Overdue and in force are both true at once; ACTIVE is the
-- document's state, overdue is a comparison against today. Migration 010 adds the
-- view that derives the second from next_review_date.
--
-- repo_path is .md, not .docx: the Markdown source in ADO becomes the controlled
-- original and the published PDF is generated from it.
-- ---------------------------------------------------------------------------
UPDATE document
SET    name                  = 'Project Request Framework',
       purpose               = 'Directs the requester to complete a form capturing the project idea and supporting preliminary information.',
       status_code           = 'ACTIVE',
       published_url         = 'https://kendallgroup.sharepoint.com/:b:/s/PMO/IQAZxufR06jgQp9_FIMXU9SYASc5Q5p5cEbkHNp8HkGw4Jc?e=fsj2dG',
       repo_path             = 'SOPs/SOP-001.md',
       review_frequency_code = 'ANNUAL',
       last_review_date      = DATE '2024-07-10',
       next_review_date      = DATE '2025-07-10',
       notes                 = 'Findings from the 2026 pilot review: '
                             || '(1) Last reviewed 2024-07-10 against an annual cadence; no mechanism flagged it as overdue. '
                             || '(2) The form is stated as a gate requirement, but compliance is measured as a percentage (M-001), '
                             ||     'which means the control is not actually enforced at the PMO approval gate. '
                             || '(3) The document referenced an individual employee email address rather than a monitored shared '
                             ||     'mailbox; changing to PMO@kendallgroup.com so submissions survive personnel changes.',
       updated_at            = now()
WHERE  document_code = 'SOP-001';

-- ---------------------------------------------------------------------------
-- FORM-001
--
-- repo_path stays NULL. Whether the form's source belongs under version control
-- alongside the SOP has not been decided. NULL records that as undecided rather
-- than asserting it lives nowhere.
-- ---------------------------------------------------------------------------
UPDATE document
SET    name          = 'Project Request Form',
       purpose       = 'Captures basic project request information: the who, what, where, when, and why.',
       status_code   = 'ACTIVE',
       published_url = 'https://kendallgroup.sharepoint.com/:w:/s/PMO/IQAI7hWZOlpsTrbsVmauXxYBAWpphsDZ5s2Jjfjnet0a5RY?e=Jdf3Ha',
       notes         = 'Published file name is "01_Project Idea Form.docx"; users refer to it as the Project Request Form. '
                     || 'Field-level content is not modeled yet — see the deferred document_field work.',
       updated_at    = now()
WHERE  document_code = 'FORM-001';

-- ---------------------------------------------------------------------------
-- The reference
-- ---------------------------------------------------------------------------
UPDATE document_reference
SET    context_note = 'Invoked in the Procedure section, step 4.',
       is_mandatory = true,
       updated_at   = now()
WHERE  source_document_id = (SELECT id FROM document WHERE document_code = 'SOP-001')
  AND  target_document_id = (SELECT id FROM document WHERE document_code = 'FORM-001');

-- ---------------------------------------------------------------------------
-- Approvers: Project Manager first, then PMO Manager.
--
-- 007 seeded R-001 at order 1 and R-003 at order 2. Both are required; the order
-- reverses.
--
-- NOTE: ADO branch policies enforce that all required reviewers approve, but not
-- the SEQUENCE in which they do. This order records intended practice. Enforcing
-- it would mean the status check withholds reviewer 2 until reviewer 1 approves —
-- deliberately not built for the pilot.
-- ---------------------------------------------------------------------------
UPDATE document_approver da
SET    approval_order = 2,
       reason         = 'Document owner; final approval for PMO procedures.',
       updated_at     = now()
FROM   document d, role r
WHERE  da.document_id = d.id
  AND  da.role_id = r.id
  AND  d.document_code = 'SOP-001'
  AND  r.role_code = 'R-001';

UPDATE document_approver da
SET    approval_order = 1,
       reason         = 'Reviews procedure content against how the work is actually performed before it reaches the owner.',
       updated_at     = now()
FROM   document d, role r
WHERE  da.document_id = d.id
  AND  da.role_id = r.id
  AND  d.document_code = 'SOP-001'
  AND  r.role_code = 'R-003';

-- ---------------------------------------------------------------------------
-- M-001 — Intake Request Usage Index
--
-- is_instrumented stays false and source_system_id stays NULL. The number is not
-- produced by any system today; it will be calculated by hand during the annual
-- review. That is a recorded fact about current state, not missing data entry.
-- ---------------------------------------------------------------------------
UPDATE metric
SET    name             = 'Intake Request Usage Index',
       metric_type_code = 'PERCENTAGE',
       definition       = 'The proportion of projects that passed the PMO approval gate for which a Project Request Form was submitted.',
       calculation      = 'Projects past the PMO approval gate WITH a submitted form, divided by all projects past the PMO approval gate, expressed as a percentage.',
       target_value     = '100',
       unit             = 'percent',
       capture_point    = 'Calculated manually during the annual SOP-001 review; no system produces it today.',
       is_instrumented  = false,
       notes            = 'The form is stated as a requirement of the PMO approval gate, so this measure should read 100%. '
                        || 'That it is worth measuring at all indicates the gate does not enforce the requirement. '
                        || 'Any reading below 100% is a control gap, not a data quality problem.',
       updated_at       = now()
WHERE  metric_code = 'M-001';

-- ---------------------------------------------------------------------------
-- The review cycle
--
-- 007 scheduled a 2027 review. The pilot IS the review, so this is the 2026
-- cycle. The 2025 review never happened; that gap stays visible in the fact that
-- no 2025 row exists and next_review_date is in the past.
-- ---------------------------------------------------------------------------
UPDATE document_review
SET    review_year    = 2026,
       scheduled_date = DATE '2026-09-01',
       started_date   = DATE '2026-09-01',
       notes          = 'First governed review under the ADO process. Document was last reviewed 2024-07-10; '
                      || 'the 2025 annual review did not take place.',
       updated_at     = now()
WHERE  document_id = (SELECT id FROM document WHERE document_code = 'SOP-001')
  AND  review_year = 2027;

INSERT INTO schema_migration (filename, notes)
VALUES ('009_correct_pilot_data.sql', 'Real SOP-001 pilot data replacing 007 placeholders.');

COMMIT;
