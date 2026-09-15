-- 023_business_unit_repo_system.sql
-- Records which repository system holds each department's procedures.
-- Depends on: 017 (business_unit), 021 (SYS-003)
--
-- WHY
--
-- dom_governance_check.py resolves a role to an ADO group, and groups are
-- project-scoped: the PMO Manager group lives in the PMO project, the CI Leader
-- group in the CI project. So the lookup needs to know which system to ask
-- about, and until now the script hardcoded SYS-002.
--
-- Copying that script into the CI repository would mean editing that one value —
-- a single-character difference between two otherwise identical files, invisible
-- in a diff, and exactly the kind of thing that drifts once someone updates one
-- copy and not the other.
--
-- Putting the answer in the DOM instead means the script is byte-identical in
-- every repository. It works out which system to ask about from the document it
-- is looking at:
--
--     document -> business_unit -> repo_system_id -> role_system_identity
--
-- It is also a fact worth recording on its own terms. "Which ADO project holds
-- CI's procedures" is a governance question, not a deployment detail, and the
-- DOM is where those answers belong.
--
-- Nullable: a department may exist in the model before it has a repository.
-- A NULL simply means no automated governance is wired up for it yet.

BEGIN;

ALTER TABLE business_unit
    ADD COLUMN repo_system_id bigint REFERENCES system(id);

COMMENT ON COLUMN business_unit.repo_system_id IS
    'Repository system holding this department''s controlled procedure source, and whose groups its roles resolve against. NULL means no governed repository yet.';

UPDATE business_unit bu
SET    repo_system_id = s.id,
       updated_at     = now()
FROM   system s
WHERE  bu.business_unit_code = 'PMO'
  AND  s.system_code = 'SYS-002';

UPDATE business_unit bu
SET    repo_system_id = s.id,
       updated_at     = now()
FROM   system s
WHERE  bu.business_unit_code = 'CI'
  AND  s.system_code = 'SYS-003';

INSERT INTO schema_migration (filename, notes)
VALUES ('023_business_unit_repo_system.sql',
        'business_unit.repo_system_id; PMO -> SYS-002, CI -> SYS-003.');

COMMIT;
