-- 021_ci_system_and_roles.sql
-- Adds the CI Azure DevOps project as a system, and the two CI approver roles.
-- Depends on: 017 (business_unit), 018 (role.business_unit_id)
--
-- WHY CI'S ADO PROJECT IS A SEPARATE SYSTEM ROW
--
-- SYS-002 is the PMO project. CI is a different project, different repository,
-- different URL, and — the part that matters — different groups.
--
-- role_system_identity maps a role to its representation in a given system. The
-- CI Leader group lives in the CI project, so resolving it requires knowing
-- which system is being asked about. One shared "Azure DevOps" row would make
-- that lookup ambiguous the moment both projects have a group of the same name.
--
-- WHAT IS NOT HERE
--
-- role_system_identity rows. Those need the vssgp. descriptors from the ADO
-- groups, which have to be created in the CI project first. Migration 022.
--
-- document_approver rows. Those attach approvers to a specific document, and no
-- CI document exists yet. They arrive with the first one.
--
-- A CI process. Nothing has been identified yet; an empty placeholder would be
-- inventing a fact rather than recording one.

BEGIN;

-- ---------------------------------------------------------------------------
-- The CI Azure DevOps project
-- ---------------------------------------------------------------------------
INSERT INTO system (system_code, name, system_type, current_state_role, base_url, owner_role_id, notes)
SELECT 'SYS-003',
       'Azure DevOps (CI)',
       'Repository',
       'Controlled source, change history, and pull-request governance for Continuous Improvement procedures.',
       'https://dev.azure.com/BradSpiech/CI%20-%20Procedure%20Review/_git/CI%20-%20Procedure%20Review',
       r.id,
       'Separate ADO project from SYS-002. Same organization, same DOM, its own repository, pipeline, and groups.'
FROM   role r
WHERE  r.role_code = 'R-001';   -- PMO Manager owns the tooling for now

-- ---------------------------------------------------------------------------
-- CI roles
--
-- Titles, never people. Membership of the corresponding ADO groups is maintained
-- in ADO, which is what lets someone change jobs without any document changing.
-- ---------------------------------------------------------------------------
INSERT INTO role (role_code, name, role_type, purpose, responsibility_summary, approval_authority, business_unit_id)
SELECT 'R-004',
       'CI Leader',
       'CI Role',
       'Accountable for the Continuous Improvement function and its procedures.',
       'Owns CI procedure content and the annual review cycle.',
       'Final approver for CI procedures.',
       bu.id
FROM   business_unit bu
WHERE  bu.business_unit_code = 'CI';

INSERT INTO role (role_code, name, role_type, purpose, responsibility_summary, approval_authority, business_unit_id)
SELECT 'R-005',
       'CI Manager',
       'CI Role',
       'Runs Continuous Improvement activity day to day.',
       'Reviews procedure content against how the work is actually performed.',
       'First approver on CI procedure changes.',
       bu.id
FROM   business_unit bu
WHERE  bu.business_unit_code = 'CI';

-- ---------------------------------------------------------------------------
-- CI now has an owner
--
-- 017 left this NULL because no CI role existed yet — the circular reference
-- between business_unit and role, resolved by filling it in afterwards.
-- ---------------------------------------------------------------------------
UPDATE business_unit bu
SET    owner_role_id = r.id,
       updated_at    = now()
FROM   role r
WHERE  bu.business_unit_code = 'CI'
  AND  r.role_code = 'R-004';

INSERT INTO schema_migration (filename, notes)
VALUES ('021_ci_system_and_roles.sql',
        'SYS-003 CI ADO project; R-004 CI Leader; R-005 CI Manager; CI owner assigned.');

COMMIT;
