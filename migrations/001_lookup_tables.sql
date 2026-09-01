-- 001_lookup_tables.sql
-- Creates the controlled-vocabulary tables used by the document governance model
-- and seeds their allowed values.
-- Depends on: nothing (first migration)
--
-- Convention note: lookup tables use a plain `code` business key, matching the
-- handbook's own example (REFERENCES relationship_type(code)). Entity tables use
-- the <table>_code form. Both appear in the handbook; this is the split.

BEGIN;

-- ---------------------------------------------------------------------------
-- document_type
-- The code doubles as the ID prefix for documents of that type, so SOP-001 is
-- validated against the type row rather than a hardcoded regex per document.
-- ---------------------------------------------------------------------------
CREATE TABLE document_type (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_type_code_format CHECK (code ~ '^[A-Z]{2,4}$')
);

INSERT INTO document_type (code, name, description) VALUES
    ('SOP',  'Standard Operating Procedure', 'Governs how a process is performed.'),
    ('POL',  'Policy',                       'States a rule or requirement.'),
    ('WI',   'Work Instruction',             'Task-level detail subordinate to an SOP.'),
    ('FORM', 'Form',                         'Structured capture instrument referenced by a procedure.'),
    ('TMP',  'Template',                     'Reusable starting document referenced by a procedure.');

-- ---------------------------------------------------------------------------
-- document_status
-- ---------------------------------------------------------------------------
CREATE TABLE document_status (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO document_status (code, name, description) VALUES
    ('DRAFT',        'Draft',        'Not yet approved; not published.'),
    ('IN_REVIEW',    'In Review',    'Change in flight; a pull request is open.'),
    ('ACTIVE',       'Active',       'Approved and published; the governing version.'),
    ('NEEDS_REVIEW', 'Needs Review', 'Past its next review date.'),
    ('RETIRED',      'Retired',      'No longer in force; retained for history.');

-- ---------------------------------------------------------------------------
-- reference_type
-- How one document points at another. This is what makes "Form: FORM-001"
-- resolvable instead of a hardcoded URL inside the SOP body.
-- ---------------------------------------------------------------------------
CREATE TABLE reference_type (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO reference_type (code, name, description) VALUES
    ('USES_FORM',     'Uses form',       'The procedure requires this form to be completed.'),
    ('USES_TEMPLATE', 'Uses template',   'The procedure starts from this template.'),
    ('CITES_POLICY',  'Cites policy',    'The procedure operates under this policy.'),
    ('RELATED',       'Related',         'Related reading; no dependency implied.'),
    ('SUPERSEDES',    'Supersedes',      'This document replaces the target document.');

-- ---------------------------------------------------------------------------
-- review_frequency
-- months_between drives next_review_date arithmetic; NULL means ad hoc.
-- ---------------------------------------------------------------------------
CREATE TABLE review_frequency (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE,
    name           text NOT NULL,
    months_between integer,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT review_frequency_months_positive
        CHECK (months_between IS NULL OR months_between > 0)
);

INSERT INTO review_frequency (code, name, months_between) VALUES
    ('ANNUAL',    'Annual',        12),
    ('BIENNIAL',  'Biennial',      24),
    ('QUARTERLY', 'Quarterly',      3),
    ('AS_NEEDED', 'As needed',   NULL);

-- ---------------------------------------------------------------------------
-- review_outcome
-- ---------------------------------------------------------------------------
CREATE TABLE review_outcome (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO review_outcome (code, name, description) VALUES
    ('NO_CHANGE',    'Approved, no change',    'Reviewed and reaffirmed as written.'),
    ('CHANGED',      'Approved with changes',  'Content revised and approved.'),
    ('RETIRED',      'Retired',                'Document withdrawn from service.'),
    ('DEFERRED',     'Deferred',               'Review postponed; document remains in force.');

-- ---------------------------------------------------------------------------
-- metric_type
-- Values carried over from the Choice Values sheet of PMO_Digital_Model_Schema_v1.
-- ---------------------------------------------------------------------------
CREATE TABLE metric_type (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO metric_type (code, name) VALUES
    ('COUNT',      'Count'),
    ('STATUS',     'Status'),
    ('DURATION',   'Duration'),
    ('SCORE',      'Score'),
    ('DATE',       'Date'),
    ('CURRENCY',   'Currency'),
    ('CHOICE',     'Choice'),
    ('PERCENTAGE', 'Percentage');

COMMIT;
