-- 004_document.sql
-- Creates the governed document entity and its two junction tables.
-- Depends on: 001 (lookups), 002 (role, system), 003 (process)
--
-- DESIGN DECISION: the form is a document, not an artifact.
--
-- Schema v1 puts forms under Artifacts (Artifact_Category = 'Form'). For the
-- intake workflow that is right: an artifact there is something a step produces
-- or consumes. But the thing SOP-001 references is not a work product — it is a
-- controlled instrument with an owner, a location, and a version. It needs the
-- same fields the SOP needs. Modeling it as a second document row makes the
-- reference a self-join and keeps one resolution path for every reference type.
--
-- When the intake model is built, artifact can carry a nullable document_id for
-- the cases where an artifact IS a controlled document. That is the join, and it
-- is cheaper than keeping two half-overlapping location models.

BEGIN;

-- ---------------------------------------------------------------------------
-- document
--
-- published_url  = where employees read it (SharePoint)
-- repo_path      = where the controlled source lives (ADO Git)
--
-- Two separate columns on purpose. They are different systems with different
-- audiences, and conflating them is what the current SOP does by hardcoding a
-- SharePoint link into its body.
-- ---------------------------------------------------------------------------
CREATE TABLE document (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_code          text NOT NULL UNIQUE,
    name                   text NOT NULL,
    document_type_code     text NOT NULL REFERENCES document_type(code),
    status_code            text NOT NULL DEFAULT 'DRAFT' REFERENCES document_status(code),
    purpose                text,

    owner_role_id          bigint NOT NULL REFERENCES role(id),
    governs_process_id     bigint REFERENCES process(id),

    storage_system_id      bigint REFERENCES system(id),
    published_url          text,
    repo_path              text,

    review_frequency_code  text REFERENCES review_frequency(code),
    last_review_date       date,
    next_review_date       date,

    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    -- The ID prefix is enforced against the document's own type row, so SOP-001
    -- can never be typed as a FORM and FORM-001 can never be typed as an SOP.
    CONSTRAINT document_code_matches_type
        CHECK (document_code ~ ('^' || document_type_code || '-[0-9]{3}$')),

    CONSTRAINT document_review_dates_ordered
        CHECK (last_review_date IS NULL
               OR next_review_date IS NULL
               OR next_review_date > last_review_date)
);

CREATE INDEX document_next_review_date_idx ON document (next_review_date);
CREATE INDEX document_owner_role_id_idx    ON document (owner_role_id);

-- ---------------------------------------------------------------------------
-- document_reference
--
-- This is the indirection layer. The SOP body says "Form: FORM-001". This table
-- says FORM-001 is what SOP-001 means by that. document.published_url says where
-- FORM-001 currently lives. Moving the form is a one-row update here, with no
-- edit to the SOP and no new review cycle.
--
-- Junction tables get no <table>_code business key — the pair of FKs plus the
-- type IS the key. This is a deliberate departure from the handbook's "every
-- table gets these" rule, which is written for entity tables.
-- ---------------------------------------------------------------------------
CREATE TABLE document_reference (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_document_id   bigint NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    target_document_id   bigint NOT NULL REFERENCES document(id),
    reference_type_code  text   NOT NULL REFERENCES reference_type(code),

    -- A mandatory reference means the procedure cannot be performed without the
    -- target. An informational one means losing it degrades rather than blocks.
    -- This is the distinction that makes impact analysis worth running.
    is_mandatory         boolean NOT NULL DEFAULT true,

    -- References sharing a group value are alternatives (OR'd, not AND'd).
    -- Two forms that satisfy the same need share a group; losing one is survivable.
    alternative_group    text,

    context_note         text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_reference_not_self
        CHECK (source_document_id <> target_document_id),
    CONSTRAINT document_reference_unique
        UNIQUE (source_document_id, target_document_id, reference_type_code)
);

CREATE INDEX document_reference_target_idx ON document_reference (target_document_id);

-- ---------------------------------------------------------------------------
-- document_approver
--
-- The governance rule that currently lives in someone's memory. This is the
-- table the ADO PR status check will query: given a document code, return the
-- roles whose approval is required before merge.
-- ---------------------------------------------------------------------------
CREATE TABLE document_approver (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id    bigint NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    role_id        bigint NOT NULL REFERENCES role(id),

    is_required    boolean NOT NULL DEFAULT true,
    approval_order integer,
    reason         text,

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_approver_unique UNIQUE (document_id, role_id),
    CONSTRAINT document_approver_order_positive
        CHECK (approval_order IS NULL OR approval_order > 0)
);

CREATE INDEX document_approver_document_id_idx ON document_approver (document_id);

COMMIT;
