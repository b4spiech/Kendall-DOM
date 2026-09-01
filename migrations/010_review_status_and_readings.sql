-- 010_review_status_and_readings.sql
-- Adds role contact addresses, metric readings, and a view that derives overdue
-- status instead of storing it.
-- Depends on: 001 (document_status), 002 (role), 005 (metric), 006 (document_review)

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. role.contact_address
--
-- From the pilot finding: SOP-001 referenced an individual's email address. A
-- person leaves and the document still reads correctly while routing submissions
-- into a dead mailbox — the same silent-breakage failure as a hardcoded URL.
--
-- The address belongs to the ROLE, not to a person. When the mailbox changes, one
-- row updates and every document referencing that role stays correct.
-- ---------------------------------------------------------------------------
ALTER TABLE role ADD COLUMN contact_address text;

COMMENT ON COLUMN role.contact_address IS
    'Monitored shared mailbox or distribution list for this role. Never an individual''s address.';

UPDATE role
SET    contact_address = 'PMO@kendallgroup.com',
       updated_at      = now()
WHERE  role_code IN ('R-001', 'R-003');

-- ---------------------------------------------------------------------------
-- 2. metric_reading
--
-- One row per measurement, taken annually during the document review.
--
-- numerator and denominator are stored separately from the computed value on
-- purpose: 3 of 4 and 750 of 1000 are both 75%, and the difference matters when
-- you are deciding whether a control gap is systemic or anecdotal.
--
-- document_review_id links the reading to the review cycle that produced it. The
-- ADO work item drives the ACTIVITY of measuring; this table holds the RESULT, so
-- the number survives the work item being closed, moved, or cleaned up — and so
-- it can be trended across years with a query rather than by opening work items
-- one at a time.
-- ---------------------------------------------------------------------------
CREATE TABLE metric_reading (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_id           bigint NOT NULL REFERENCES metric(id),

    period_start        date NOT NULL,
    period_end          date NOT NULL,

    numerator           numeric,
    denominator         numeric,
    value_numeric       numeric,

    captured_at         timestamptz NOT NULL DEFAULT now(),
    captured_by         text,
    source_note         text,

    document_review_id  bigint REFERENCES document_review(id),

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT metric_reading_period_ordered
        CHECK (period_end >= period_start),
    CONSTRAINT metric_reading_denominator_nonzero
        CHECK (denominator IS NULL OR denominator <> 0),
    CONSTRAINT metric_reading_unique_period
        UNIQUE (metric_id, period_start, period_end)
);

CREATE INDEX metric_reading_metric_id_idx ON metric_reading (metric_id);

-- ---------------------------------------------------------------------------
-- 3. Overdue is derived, not stored
--
-- A generated column cannot do this: GENERATED ALWAYS AS requires an immutable
-- expression, and anything depending on CURRENT_DATE is not immutable — the
-- answer changes daily without the row changing. Storing it would mean rewriting
-- every row every night to keep it honest.
--
-- A view computes it at read time and is therefore never stale.
--
-- NEEDS_REVIEW is removed from document_status for the same reason: it was the
-- one status value that could be derived, and keeping it in both places is how
-- the stored value and the real answer come to disagree. The remaining statuses
-- (DRAFT, IN_REVIEW, ACTIVE, RETIRED) are states a person chooses.
-- ---------------------------------------------------------------------------
DELETE FROM document_status WHERE code = 'NEEDS_REVIEW';

CREATE VIEW document_review_status AS
SELECT d.document_code,
       d.name,
       d.status_code,
       r.name                       AS owner_role,
       d.review_frequency_code,
       d.last_review_date,
       d.next_review_date,
       CASE
           WHEN d.next_review_date IS NULL             THEN NULL
           ELSE d.next_review_date < CURRENT_DATE
       END                          AS is_overdue,
       CASE
           WHEN d.next_review_date IS NULL             THEN NULL
           WHEN d.next_review_date >= CURRENT_DATE     THEN 0
           ELSE CURRENT_DATE - d.next_review_date
       END                          AS days_overdue
FROM   document d
LEFT   JOIN role r ON r.id = d.owner_role_id;

COMMENT ON VIEW document_review_status IS
    'Current review standing per document. is_overdue is computed at read time; never stored.';

INSERT INTO schema_migration (filename, notes)
VALUES ('010_review_status_and_readings.sql',
        'role.contact_address, metric_reading, document_review_status view, NEEDS_REVIEW removed.');

COMMIT;
