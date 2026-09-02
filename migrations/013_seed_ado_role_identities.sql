-- 013_seed_ado_role_identities.sql
-- Maps R-001 (PMO Manager) and R-003 (Project Manager) to their Azure DevOps
-- groups.
-- Depends on: 012 (role_system_identity), 011 (SYS-002 base_url)
--
-- external_id is the ADO subject descriptor. It survives a group rename, which is
-- why it — and not the group name — is what automation resolves against.
--
-- The vssgp. prefix identifies these as groups rather than user accounts. A user
-- descriptor would start with aad. or msa. and would mean an individual had been
-- written back into a governance rule, which this table exists to prevent.

BEGIN;

INSERT INTO role_system_identity (role_id, system_id, external_id, external_name, identity_type, notes)
SELECT r.id,
       s.id,
       'vssgp.Uy0xLTktMTU1MTM3NDI0NS0xNTY0ODc4ODg3LTIyNDgxOTEwNDctMjIyNTE0MzExNS0yNDcyMDQ1MzQzLTEtMzQ3OTc2NzA0My0zMTkyMTgxMzI0LTI1OTI2MDcyNzctMjQ0MjcxNzU0',
       'PMO Manager',
       'group',
       'Second approver on SOP-001. Group membership is maintained in ADO, not here.'
FROM   role r, system s
WHERE  r.role_code = 'R-001'
  AND  s.system_code = 'SYS-002';

INSERT INTO role_system_identity (role_id, system_id, external_id, external_name, identity_type, notes)
SELECT r.id,
       s.id,
       'vssgp.Uy0xLTktMTU1MTM3NDI0NS0xNTY0ODc4ODg3LTIyNDgxOTEwNDctMjIyNTE0MzExNS0yNDcyMDQ1MzQzLTEtMjkyMjA2ODkxOC01MjkwODgwNzYtMjYwOTczNzA0Ny0yNjIzNjc4Mzc3',
       'Project Manager',
       'group',
       'First approver on SOP-001. Group membership is maintained in ADO, not here.'
FROM   role r, system s
WHERE  r.role_code = 'R-003'
  AND  s.system_code = 'SYS-002';

INSERT INTO schema_migration (filename, notes)
VALUES ('013_seed_ado_role_identities.sql',
        'ADO group descriptors for R-001 and R-003.');

COMMIT;
