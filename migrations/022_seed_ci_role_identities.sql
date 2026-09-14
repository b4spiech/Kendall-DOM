-- 022_seed_ci_role_identities.sql
-- Maps R-004 (CI Leader) and R-005 (CI Manager) to their Azure DevOps groups in
-- the CI project.
-- Depends on: 012 (role_system_identity), 021 (SYS-003, R-004, R-005)
--
-- Note the descriptors differ from the PMO ones from the fourth segment onward.
-- That segment identifies the project scope — these groups live in the CI
-- project, not the PMO one, which is why SYS-003 exists as a separate system
-- row. Resolving "the CI Leader group" without knowing which project to look in
-- would be ambiguous the moment two projects have groups of the same name.
--
-- external_id is the subject descriptor, which survives a group rename.
-- external_name is a readable label and is allowed to go stale; nothing resolves
-- against it.
--
-- The vssgp. prefix identifies these as groups rather than user accounts. A user
-- descriptor would start with aad. or msa. and would mean an individual had been
-- written into a governance rule, which this table exists to prevent.

BEGIN;

INSERT INTO role_system_identity (role_id, system_id, external_id, external_name, identity_type, notes)
SELECT r.id,
       s.id,
       'vssgp.Uy0xLTktMTU1MTM3NDI0NS00MDkwOTcwNjYzLTExMTcwNzQ2My0zMDQ1NzY1NjI0LTI3MjY1MDgzNzMtMS0xMjUwOTk4Nzk1LTIwMzMxMDk1ODAtMzIxNjMzNjgzNC0zMzA2MjExNDEx',
       'CI Leader',
       'group',
       'Final approver on CI procedures. Group membership is maintained in ADO, not here.'
FROM   role r, system s
WHERE  r.role_code = 'R-004'
  AND  s.system_code = 'SYS-003';

INSERT INTO role_system_identity (role_id, system_id, external_id, external_name, identity_type, notes)
SELECT r.id,
       s.id,
       'vssgp.Uy0xLTktMTU1MTM3NDI0NS00MDkwOTcwNjYzLTExMTcwNzQ2My0zMDQ1NzY1NjI0LTI3MjY1MDgzNzMtMS0yNjczODMxMjI3LTQ5NjQ0NzU1NS0yNzc2NjYyMzk3LTM1NDQzOTQwNzI',
       'CI Manager',
       'group',
       'First approver on CI procedures. Group membership is maintained in ADO, not here.'
FROM   role r, system s
WHERE  r.role_code = 'R-005'
  AND  s.system_code = 'SYS-003';

INSERT INTO schema_migration (filename, notes)
VALUES ('022_seed_ci_role_identities.sql',
        'ADO group descriptors for R-004 and R-005 in the CI project (SYS-003).');

COMMIT;
