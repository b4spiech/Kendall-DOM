-- 015_version_labels.sql
-- Adds human-meaningful version labels and the ability to close out a review.
-- Depends on: 004 (document), 006 (document_review), 014 (grants)
--
-- WHY NOT THE GIT SHA
--
-- The publish pipeline currently stamps an 8-character commit hash as the
-- version. That is precise and useless to a reader: it changes on every typo
-- fix, sorts meaninglessly, and no one can tell whether a1b3f9c2 is newer than
-- 7d4e2f81.
--
-- SOP-001 already used a scheme: 24.1 — first revision issued in 2024. This
-- keeps it. YY.N, where N restarts each year.
--
-- The SHA is still recorded, in document_review.notes, so a published PDF can
-- still be traced to an exact commit. It is just not what a reader sees.
--
-- NOT EVERY MERGE IS A REVIEW
--
-- Fixing a typo should not bump the version or reset the annual review clock.
-- Only a merge that completes a review cycle does that. The pipeline decides
-- which is which by whether the PR is linked to the review work item recorded in
-- document_review.ado_work_item_id.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The current published version lives on the document
--
-- Denormalized on purpose: it is derivable from the newest completed
-- document_review, but the publish pipeline reads it on every build and this
-- avoids a correlated subquery in the hot path. Written only by review close.
-- ---------------------------------------------------------------------------
ALTER TABLE document ADD COLUMN version_label text;

COMMENT ON COLUMN document.version_label IS
    'Current published version, format YY.N (e.g. 26.1). Set by review close, never by hand.';

-- Seed the known current version of SOP-001.
UPDATE document
SET    version_label = '24.1',
       updated_at    = now()
WHERE  document_code = 'SOP-001';

-- ---------------------------------------------------------------------------
-- 2. Next version for a document, in a given year
--
-- Looks at every version already issued for this document in that year and
-- returns the next one. 2026 with nothing prior gives 26.1; a second revision
-- the same year gives 26.2.
-- ---------------------------------------------------------------------------
CREATE FUNCTION next_version_label(p_document_code text, p_year integer)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT to_char(p_year % 100, 'FM00') || '.' ||
           (COALESCE(MAX(
               CASE
                   WHEN dr.version_label ~ ('^' || to_char(p_year % 100, 'FM00') || '\.[0-9]+$')
                   THEN split_part(dr.version_label, '.', 2)::integer
               END
           ), 0) + 1)::text
    FROM   document_review dr
    JOIN   document d ON d.id = dr.document_id
    WHERE  d.document_code = p_document_code;
$$;

COMMENT ON FUNCTION next_version_label IS
    'Next YY.N version label for a document in a given year, based on versions already issued.';

-- ---------------------------------------------------------------------------
-- 3. Close a review cycle
--
-- One call does what would otherwise be four statements a script could get half
-- right: stamps the review row, assigns the version, moves the document dates
-- forward by its own review frequency, and returns the new version.
--
-- Putting it in the database rather than in Python means the automation cannot
-- perform half of a close. Either all of it lands or none of it does.
-- ---------------------------------------------------------------------------
CREATE FUNCTION close_document_review(
    p_document_code text,
    p_review_year   integer,
    p_outcome_code  text,
    p_pull_request  text DEFAULT NULL,
    p_commit_sha    text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_document_id  bigint;
    v_review_id    bigint;
    v_version      text;
    v_months       integer;
BEGIN
    SELECT id INTO v_document_id
    FROM   document WHERE document_code = p_document_code;

    IF v_document_id IS NULL THEN
        RAISE EXCEPTION 'Document % is not in the DOM.', p_document_code;
    END IF;

    SELECT id INTO v_review_id
    FROM   document_review
    WHERE  document_id = v_document_id AND review_year = p_review_year;

    IF v_review_id IS NULL THEN
        RAISE EXCEPTION
            'No % review scheduled for %. A review must be scheduled before it can be closed.',
            p_review_year, p_document_code;
    END IF;

    IF EXISTS (SELECT 1 FROM document_review
               WHERE id = v_review_id AND completed_date IS NOT NULL) THEN
        RAISE EXCEPTION
            'The % review of % is already closed. Schedule a new review rather than reopening it.',
            p_review_year, p_document_code;
    END IF;

    v_version := next_version_label(p_document_code, p_review_year);

    UPDATE document_review
    SET    completed_date      = CURRENT_DATE,
           outcome_code        = p_outcome_code,
           version_label       = v_version,
           ado_pull_request_id = COALESCE(p_pull_request, ado_pull_request_id),
           notes               = COALESCE(notes || ' ', '')
                                 || 'Closed at commit ' || COALESCE(p_commit_sha, 'unknown') || '.',
           updated_at          = now()
    WHERE  id = v_review_id;

    -- Move the clock forward by the document's own cadence, not a hardcoded year.
    SELECT rf.months_between INTO v_months
    FROM   document d
    LEFT   JOIN review_frequency rf ON rf.code = d.review_frequency_code
    WHERE  d.id = v_document_id;

    UPDATE document
    SET    last_review_date = CURRENT_DATE,
           next_review_date = CASE
                                  WHEN v_months IS NULL THEN NULL
                                  ELSE CURRENT_DATE + (v_months || ' months')::interval
                              END,
           version_label    = v_version,
           status_code      = CASE WHEN p_outcome_code = 'RETIRED'
                                   THEN 'RETIRED' ELSE 'ACTIVE' END,
           updated_at       = now()
    WHERE  id = v_document_id;

    RETURN v_version;
END;
$$;

COMMENT ON FUNCTION close_document_review IS
    'Completes a review cycle: stamps the review, assigns the next version, and rolls the document dates forward. Returns the new version label.';

-- ---------------------------------------------------------------------------
-- 4. Grants
--
-- dom_writer can close a review. It still cannot change owners, approvers, or
-- locations — see 014. version_label is added to its column-level UPDATE grant
-- because closing a review necessarily sets it.
-- ---------------------------------------------------------------------------
GRANT UPDATE (version_label) ON document TO dom_writer;
GRANT EXECUTE ON FUNCTION next_version_label(text, integer)   TO dom_reader, dom_writer;
GRANT EXECUTE ON FUNCTION close_document_review(text, integer, text, text, text) TO dom_writer;

INSERT INTO schema_migration (filename, notes)
VALUES ('015_version_labels.sql',
        'document.version_label, next_version_label(), close_document_review().');

COMMIT;
