-- 017_business_unit.sql
-- Adds the business unit as a first-class entity.
-- Depends on: 002 (role)
--
-- WHY THIS EXISTS
--
-- Everything in the DOM so far is implicitly PMO. Nothing records it, because
-- there was nothing else. Adding a second department (Continuous Improvement)
-- makes "show me what CI owns" a question the model cannot currently answer, and
-- "who owns this process" ambiguous.
--
-- WHY A TABLE RATHER THAN A TEXT COLUMN
--
-- A text column on document would accept 'CI', 'C.I.', and 'Continuous
-- Improvement' as three different departments. The query for everything CI owns
-- would then silently miss two thirds of it — no error, just a wrong answer,
-- which is the worst kind.
--
-- A table plus a foreign key means the database refuses anything that is not a
-- real business unit. It also gives the unit somewhere to grow: an owning
-- executive today, a default review cadence or a SharePoint site later, as
-- columns on a table that already exists rather than a schema change under
-- pressure.
--
-- THE CODE DOUBLES AS THE DOCUMENT PREFIX
--
-- business_unit_code is what appears at the front of a document code:
--
--     PMO-SOP-001
--     CI-SOP-101
--     ^^^
--
-- Exactly the way document_type.code already supplies the middle segment. That
-- is what lets migration 019 validate a full document code against both tables
-- without hardcoding a list of departments anywhere.
--
-- THE CIRCULAR REFERENCE
--
-- business_unit.owner_role_id points at role, and role.business_unit_id (added
-- in 018) points back. Neither row can be inserted first if both columns are
-- required.
--
-- owner_role_id is nullable, which resolves it: insert the unit with NULL,
-- insert its roles, then UPDATE the unit to point at its owner. NULL satisfies a
-- foreign key trivially because there is nothing to check.
--
-- That is not a workaround. "Owner not yet assigned" is a real state — a
-- department can exist before anyone is named to run it — so the nullable column
-- is the honest model and the ordering problem disappears as a side effect.
--
-- (Postgres also offers DEFERRABLE INITIALLY DEFERRED, which postpones the check
-- to COMMIT and would allow a genuinely required mutual reference. Not needed
-- here, and worth avoiding while the simpler answer is also the truer one.)

BEGIN;

CREATE TABLE business_unit (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_unit_code  text NOT NULL UNIQUE,
    name                text NOT NULL,

    -- Nullable by design. See the note above.
    owner_role_id       bigint REFERENCES role(id),

    -- Retire a dissolved department without deleting it. Its documents, reviews,
    -- and approval history stay readable, which is the whole point of keeping
    -- governance records.
    is_active           boolean NOT NULL DEFAULT true,

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    -- Two to five uppercase letters. Short because it prefixes every document
    -- code and filename in that department; letters only so the code never needs
    -- escaping in a path, a URL, or a regex.
    CONSTRAINT business_unit_code_format CHECK (business_unit_code ~ '^[A-Z]{2,5}$')
);

COMMENT ON TABLE business_unit IS
    'Departments that own governed documents. business_unit_code is the first segment of a document code, e.g. the PMO in PMO-SOP-001.';

COMMENT ON COLUMN business_unit.owner_role_id IS
    'Role accountable for the unit. Nullable: a unit may exist before an owner is named.';

INSERT INTO business_unit (business_unit_code, name, notes) VALUES
    ('PMO', 'Program Management Office',
     'First department onto the governed review process.'),
    ('CI',  'Continuous Improvement',
     'Second department. Separate ADO project and repository, same DOM.');

-- Owner assigned in a separate statement, after the unit exists. R-001 is the
-- PMO Manager, seeded in 007.
UPDATE business_unit bu
SET    owner_role_id = r.id,
       updated_at    = now()
FROM   role r
WHERE  bu.business_unit_code = 'PMO'
  AND  r.role_code = 'R-001';

-- CI's owner is left NULL until its roles exist. 021 will assign it.

GRANT SELECT ON business_unit TO dom_reader, dom_writer;

INSERT INTO schema_migration (filename, notes)
VALUES ('017_business_unit.sql',
        'business_unit table; PMO and CI seeded; PMO owner assigned.');

COMMIT;
