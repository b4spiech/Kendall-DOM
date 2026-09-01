-- 006_document_review.sql
-- Records each review cycle and who actually approved it.
-- Depends on: 001 (review_outcome), 002 (role), 004 (document)
--
-- document_approver holds the RULE (which roles must approve).
-- document_review_approval holds the EVIDENCE (who approved, when, on which PR).
--
-- Keeping them separate is what makes the audit trail survive a rule change: if
-- Finance is added as an approver next year, last year's completed review still
-- reads correctly instead of retroactively looking non-compliant.

BEGIN;

CREATE TABLE document_review (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id          bigint  NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    review_year          integer NOT NULL,

    scheduled_date       date,
    started_date         date,
    completed_date       date,

    outcome_code         text REFERENCES review_outcome(code),
    version_label        text,

    -- Traceability back into ADO. Text, not integer: work item and PR IDs are
    -- identifiers, not quantities, and we never do arithmetic on them.
    ado_work_item_id     text,
    ado_pull_request_id  text,
    published_url        text,

    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_review_unique UNIQUE (document_id, review_year),
    CONSTRAINT document_review_year_sane CHECK (review_year BETWEEN 2020 AND 2100),
    CONSTRAINT document_review_dates_ordered
        CHECK (started_date IS NULL
               OR completed_date IS NULL
               OR completed_date >= started_date),
    -- A completed review must say how it came out.
    CONSTRAINT document_review_completed_has_outcome
        CHECK (completed_date IS NULL OR outcome_code IS NOT NULL)
);

CREATE INDEX document_review_document_id_idx ON document_review (document_id);

CREATE TABLE document_review_approval (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_review_id   bigint NOT NULL REFERENCES document_review(id) ON DELETE CASCADE,
    role_id              bigint NOT NULL REFERENCES role(id),

    -- The person who held the role at approval time. Captured as text on purpose:
    -- this is a historical record, not a live directory reference, and it must
    -- stay readable after that person leaves.
    approved_by          text,
    approved_at          timestamptz,
    approval_source      text,

    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_review_approval_unique UNIQUE (document_review_id, role_id)
);

COMMIT;
