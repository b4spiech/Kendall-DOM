-- 034_ad_hoc_review_close.sql
-- Removes the "a review must already be scheduled" requirement from closing
-- one, and drops review_year as an argument close_document_review's caller
-- has to know.
-- Depends on: 006 (document_review), 015 (close_document_review, version_label)
--
-- WHY
--
-- The publishing repo closes a review when a PR from a branch like
-- review/PMO-SOP-002 merges to main. The branch carries no year -- there is
-- nothing left for a caller to pass except the document code, the outcome,
-- and the PR/commit that closed it. The current signature requires a
-- review_year that identifies a row document_review already has to contain,
-- or the function raises 'No 2026 review scheduled for PMO-SOP-002' and
-- refuses. A review should be closeable whenever the work that closes it
-- actually happens, not only when someone pre-scheduled that exact year.
--
-- WHAT STAYS
--
-- A document that WAS scheduled in advance -- PMO-SOP-002 and every CI-SOP
-- document currently carry an incomplete document_review row for 2027 --
-- still gets that row completed in place when the close happens to land in
-- 2027, preserving its scheduled_date and any ado_work_item_id it already
-- carries. Ad hoc only means a schedule is no longer REQUIRED; using one
-- when it exists and matches the current year is still correct and is not
-- removed.
--
-- THE CONSTRAINT THAT HAD TO CHANGE
--
-- document_review_unique enforced one row per (document, year) -- correct
-- when a year could hold at most one scheduled review, wrong the moment a
-- second ad hoc close in the same year needs to exist as its own row (this
-- is exactly how 26.1 -> 26.2 within one year is recorded; PMO-SOP-001
-- already has a completed 2026 row, so closing it again this year must
-- INSERT a second one). Replaced with two narrower guarantees that protect
-- what the original constraint was actually for:
--   - at most one PENDING (uncompleted) row per document per year, so two
--     schedules can't collide -- unaffected by ad hoc closes, which always
--     land completed;
--   - at most one row per (document, PR), so a webhook retry on the same
--     merged PR can't record a second closure.
--
-- THE OLD FIVE-ARGUMENT FUNCTION
--
-- Dropped, not wrapped. A compatibility wrapper only makes sense when the
-- old and new behavior can coexist; here the old signature's entire reason
-- to exist was requiring a pre-scheduled review_year, which is precisely
-- the restriction this migration removes. Wrapping it would mean keeping a
-- second, contradictory closing path alongside the real one. This repo has
-- one other consumer of close_document_review (the publishing repo, per
-- the request that produced this migration) and no access from here to
-- confirm nothing else calls the five-argument form -- that repo is not
-- checked out in this workspace to search. Flagged in the migration report,
-- not silently assumed: if another caller still depends on
-- close_document_review(text, integer, text, text, text), it will now get
-- an undefined-function error instead of a silent wrong answer, and needs
-- updating to the four-argument form before this migration reaches it.
--
-- IDEMPOTENCY
--
-- Written to run once, like every migration in this ledger -- not
-- defensively re-runnable. DROP FUNCTION / CREATE FUNCTION (not CREATE OR
-- REPLACE) fails loudly on a second run instead of silently reapplying,
-- the same convention CREATE TABLE already follows here.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. document_review: one row per (document, year) is no longer true once
-- ad hoc closes can add a second review within a year. Replaced with the
-- two narrower guarantees described above.
-- ---------------------------------------------------------------------------
ALTER TABLE document_review DROP CONSTRAINT document_review_unique;

CREATE UNIQUE INDEX document_review_one_pending_per_year
    ON document_review (document_id, review_year)
    WHERE completed_date IS NULL;

CREATE UNIQUE INDEX document_review_unique_pr
    ON document_review (document_id, ado_pull_request_id)
    WHERE ado_pull_request_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Drop the old five-argument close_document_review. See header.
-- ---------------------------------------------------------------------------
DROP FUNCTION close_document_review(text, integer, text, text, text);

-- ---------------------------------------------------------------------------
-- 3. close_document_review, ad hoc.
--
-- No review_year argument -- the current calendar year is used directly,
-- same as a caller today would only ever pass CURRENT year anyway now that
-- nothing upstream tracks one. next_version_label is unchanged: it already
-- computes the next revision from document_review.version_label rows
-- matching a given year, which is exactly what both the same-year-increment
-- and cross-year-rollover requirements need, and neither behavior is new
-- here.
--
-- Prefers completing an existing pending review for the current year over
-- creating a new one, so a document that was scheduled in advance keeps its
-- scheduled_date and any ado_work_item_id when the close happens to land in
-- the year it was scheduled for. Falls back to inserting a fresh ad hoc row
-- when there is nothing pending for the current year -- which is the normal
-- case now, and the whole point of this migration.
-- ---------------------------------------------------------------------------
CREATE FUNCTION close_document_review(
    p_document_code text,
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
    v_review_year  integer := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    v_version      text;
    v_months       integer;
BEGIN
    SELECT id INTO v_document_id
    FROM   document WHERE document_code = p_document_code;

    IF v_document_id IS NULL THEN
        RAISE EXCEPTION 'Document % is not in the DOM.', p_document_code;
    END IF;

    -- A merged PR should close a review exactly once. document_review_unique_pr
    -- enforces this at the constraint level regardless; checked explicitly
    -- first for a legible error instead of a raw unique-violation.
    IF p_pull_request IS NOT NULL AND EXISTS (
        SELECT 1 FROM document_review
        WHERE  document_id = v_document_id AND ado_pull_request_id = p_pull_request
    ) THEN
        RAISE EXCEPTION
            'PR % has already closed a review for %. Not closing it again.',
            p_pull_request, p_document_code;
    END IF;

    v_version := next_version_label(p_document_code, v_review_year);

    SELECT id INTO v_review_id
    FROM   document_review
    WHERE  document_id = v_document_id
      AND  review_year = v_review_year
      AND  completed_date IS NULL
    ORDER BY created_at
    LIMIT 1;

    IF v_review_id IS NOT NULL THEN
        UPDATE document_review
        SET    completed_date      = CURRENT_DATE,
               outcome_code        = p_outcome_code,
               version_label       = v_version,
               ado_pull_request_id = COALESCE(p_pull_request, ado_pull_request_id),
               notes               = COALESCE(notes || ' ', '')
                                     || 'Closed at commit ' || COALESCE(p_commit_sha, 'unknown') || '.',
               updated_at          = now()
        WHERE  id = v_review_id;
    ELSE
        INSERT INTO document_review (
            document_id, review_year, completed_date, outcome_code, version_label,
            ado_pull_request_id, notes
        ) VALUES (
            v_document_id, v_review_year, CURRENT_DATE, p_outcome_code, v_version,
            p_pull_request, 'Closed at commit ' || COALESCE(p_commit_sha, 'unknown') || '.'
        );
    END IF;

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

COMMENT ON FUNCTION close_document_review(text, text, text, text) IS
    'Closes a review ad hoc: no prior scheduling required. Completes a pending review_document row for the current year if one exists, otherwise inserts one. Stamps the review, assigns the next version, and rolls the document dates forward. Returns the new version label.';

-- ---------------------------------------------------------------------------
-- 4. Grants. dom_writer already has INSERT and UPDATE on document_review
-- (014) -- the ad hoc INSERT path needs no new grant, only the EXECUTE grant
-- moving to the new signature. Nothing is broadened beyond that.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION close_document_review(text, text, text, text) TO dom_writer;

INSERT INTO schema_migration (filename, notes)
VALUES ('034_ad_hoc_review_close.sql',
        'close_document_review(text,text,text,text) replaces the five-argument, scheduling-required version (dropped). document_review_unique replaced by one-pending-per-year and one-row-per-PR.');

COMMIT;
