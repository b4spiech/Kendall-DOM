-- 007_seed_pilot_sop.sql
-- Seeds the single-SOP pilot: one SOP, the form it references, the process it
-- governs, the KPI that measures that process, and the roles involved.
-- Depends on: 001-006
--
-- >>> EVERY VALUE MARKED [FILL] IS A PLACEHOLDER. Replace before running. <<<
--
-- All foreign keys are resolved by business code via SELECT, never by hardcoded
-- id, per handbook section 6. This file will produce identical results against a
-- freshly rebuilt database regardless of insert order.

BEGIN;

-- ---------------------------------------------------------------------------
-- Roles
-- Titles, never people. Add one row per role that owns or approves the SOP.
-- ---------------------------------------------------------------------------
INSERT INTO role (role_code, name, role_type, purpose, approval_authority) VALUES
    ('R-001', 'PMO Manager',        'PMO Role',
     'Owns PMO procedures and the annual review cycle.',
     'Owner and final approver for PMO SOPs.'),
    ('R-002', 'EVP of Operations',  'Sponsor Role',
     'Executive accountability for operations processes.',
     'Approves SOPs with cross-functional operational impact.'),
    ('R-003', '[FILL] Cross-BU Approver Title', '[FILL] Role Type',
     '[FILL] Why this role must approve.',
     '[FILL] Scope of their approval authority.');

-- ---------------------------------------------------------------------------
-- Systems
-- ---------------------------------------------------------------------------
INSERT INTO system (system_code, name, system_type, current_state_role, base_url) VALUES
    ('SYS-001', 'SharePoint',   'Repository',
     'Employee-facing published document library.',
     '[FILL] https://kendallgroup.sharepoint.com/sites/...'),
    ('SYS-002', 'Azure DevOps', 'Repository',
     'Controlled source, change history, and pull-request governance.',
     '[FILL] https://dev.azure.com/...');

-- Owner assignment done as a separate UPDATE so the role lookup is explicit.
UPDATE system s
SET    owner_role_id = r.id
FROM   role r
WHERE  r.role_code = 'R-001'
  AND  s.system_code IN ('SYS-001', 'SYS-002');

-- ---------------------------------------------------------------------------
-- Process
-- The thing the SOP governs and the KPI measures.
-- ---------------------------------------------------------------------------
INSERT INTO process (process_code, name, purpose, owner_role_id)
SELECT 'PROC-001',
       '[FILL] Name of the process this SOP governs',
       '[FILL] What the process exists to accomplish.',
       r.id
FROM   role r
WHERE  r.role_code = 'R-001';

-- ---------------------------------------------------------------------------
-- Documents
-- The SOP and the form it references, as two rows in one table.
-- ---------------------------------------------------------------------------
INSERT INTO document (
        document_code, name, document_type_code, status_code, purpose,
        owner_role_id, governs_process_id, storage_system_id,
        published_url, repo_path,
        review_frequency_code, last_review_date, next_review_date)
SELECT 'SOP-001',
       '[FILL] SOP title exactly as it appears on the document',
       'SOP',
       'ACTIVE',
       '[FILL] What this SOP tells people to do.',
       r.id,
       p.id,
       s.id,
       '[FILL] current SharePoint URL of the published SOP',
       'SOPs/SOP-001.docx',
       'ANNUAL',
       NULL,                                    -- [FILL] date of last real review, if known
       DATE '2027-09-01'                        -- [FILL] first governed review date
FROM   role r
CROSS  JOIN process p
CROSS  JOIN system s
WHERE  r.role_code = 'R-001'
  AND  p.process_code = 'PROC-001'
  AND  s.system_code = 'SYS-001';

INSERT INTO document (
        document_code, name, document_type_code, status_code, purpose,
        owner_role_id, storage_system_id, published_url,
        review_frequency_code)
SELECT 'FORM-001',
       '[FILL] Form name as it appears to users',
       'FORM',
       'ACTIVE',
       '[FILL] What the form captures.',
       r.id,
       s.id,
       '[FILL] current SharePoint URL of the form — the link currently hardcoded in the SOP',
       'ANNUAL'
FROM   role r
CROSS  JOIN system s
WHERE  r.role_code = 'R-001'
  AND  s.system_code = 'SYS-001';

-- ---------------------------------------------------------------------------
-- The reference: SOP-001 uses FORM-001
-- After this row exists, the SOP body should say "Form: FORM-001" and the URL
-- should be deleted from the document. That edit is the point of the pilot.
-- ---------------------------------------------------------------------------
INSERT INTO document_reference (
        source_document_id, target_document_id, reference_type_code,
        is_mandatory, context_note)
SELECT src.id, tgt.id, 'USES_FORM', true,
       '[FILL] Where in the SOP the form is invoked, e.g. "Section 4, step 2".'
FROM   document src, document tgt
WHERE  src.document_code = 'SOP-001'
  AND  tgt.document_code = 'FORM-001';

-- ---------------------------------------------------------------------------
-- Required approvers — the governance rule, made queryable
-- ---------------------------------------------------------------------------
INSERT INTO document_approver (document_id, role_id, is_required, approval_order, reason)
SELECT d.id, r.id, true, 1, 'Document owner.'
FROM   document d, role r
WHERE  d.document_code = 'SOP-001' AND r.role_code = 'R-001';

INSERT INTO document_approver (document_id, role_id, is_required, approval_order, reason)
SELECT d.id, r.id, true, 2, '[FILL] Why this business unit must approve.'
FROM   document d, role r
WHERE  d.document_code = 'SOP-001' AND r.role_code = 'R-003';

-- ---------------------------------------------------------------------------
-- The KPI
-- is_instrumented stays false: it is tracked outside any system today. That is
-- a recorded fact about current state, not an omission.
-- ---------------------------------------------------------------------------
INSERT INTO metric (
        metric_code, name, metric_type_code, definition, calculation,
        target_value, unit, capture_point, is_instrumented, owner_role_id, notes)
SELECT 'M-001',
       '[FILL] KPI name',
       'COUNT',   -- [FILL] one of: COUNT STATUS DURATION SCORE DATE CURRENCY CHOICE PERCENTAGE
       '[FILL] What the number means, in one sentence.',
       '[FILL] How it is calculated.',
       '[FILL] Target, if there is one.',
       '[FILL] Unit of measure.',
       '[FILL] Where it is tracked today — the spreadsheet, the report, the person.',
       false,
       r.id,
       'Tracked outside any system as of pilot start. No source_system_id by design.'
FROM   role r
WHERE  r.role_code = 'R-001';

INSERT INTO process_metric (process_id, metric_id, is_primary)
SELECT p.id, m.id, true
FROM   process p, metric m
WHERE  p.process_code = 'PROC-001' AND m.metric_code = 'M-001';

-- ---------------------------------------------------------------------------
-- The first scheduled review
-- ---------------------------------------------------------------------------
INSERT INTO document_review (document_id, review_year, scheduled_date, notes)
SELECT d.id, 2027, DATE '2027-09-01',
       'First governed review under the ADO process.'
FROM   document d
WHERE  d.document_code = 'SOP-001';

COMMIT;
