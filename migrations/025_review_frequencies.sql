-- 025_review_frequencies.sql
-- Adds semi-annual and monthly review cadences.
-- Depends on: 001 (review_frequency)
--
-- The table already held ANNUAL, BIENNIAL, QUARTERLY, and AS_NEEDED. These two
-- fill the gaps between them.
--
-- months_between IS THE MAPPING
--
-- The onboarding form calculates the next review date from the last review date
-- and the chosen frequency. That calculation should read months_between from
-- this table rather than carry its own copy of the intervals in JavaScript.
--
-- Two reasons. A hardcoded map has to handle the case where the DOM contains a
-- code the code does not know about — this row, added today, would have been
-- exactly that. And with the interval on the row, adding a cadence later is one
-- INSERT rather than a change in both the database and the client.
--
-- AS_NEEDED keeps months_between NULL on purpose: there is no interval, so the
-- next review date cannot be derived and should be left for a person to set.
-- NULL is the honest answer, not a missing value.

BEGIN;

INSERT INTO review_frequency (code, name, months_between) VALUES
    ('SEMI_ANNUAL', 'Semi-annual', 6),
    ('MONTHLY',     'Monthly',     1);

INSERT INTO schema_migration (filename, notes)
VALUES ('025_review_frequencies.sql',
        'SEMI_ANNUAL (6 months) and MONTHLY (1 month) added to review_frequency.');

COMMIT;
