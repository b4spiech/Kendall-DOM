-- 014_service_role_grants.sql
-- Grants for the two service accounts that automation uses.
-- Depends on: all prior migrations (grants reference the tables they created)
--
-- PREREQUISITE — run these by hand BEFORE this migration. They are not in this
-- file because this file is committed to git and passwords must not be:
--
--   CREATE ROLE dom_reader LOGIN PASSWORD '<generate one>';
--   CREATE ROLE dom_writer LOGIN PASSWORD '<generate a different one>';
--
-- Generate with: openssl rand -base64 24
--
-- THE PRINCIPLE
--
-- Automation records what happened. It does not redefine what is governed.
--
--   Outcomes of the process running  -> writable by automation
--     review dates, outcomes, PR ids, approval records, metric readings
--
--   Governance decisions             -> NOT writable by automation
--     who approves, who owns, where the document lives, review frequency
--
-- A merge can close out a review cycle. It cannot reassign ownership, change an
-- approver, or repoint a document. Those require a human and a migration.

BEGIN;

-- Fail early and legibly if the prerequisite was skipped, rather than emitting
-- eight confusing "role does not exist" errors.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dom_reader') THEN
        RAISE EXCEPTION 'Role dom_reader does not exist. Create dom_reader and dom_writer first — see the header of this file.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dom_writer') THEN
        RAISE EXCEPTION 'Role dom_writer does not exist. Create dom_reader and dom_writer first — see the header of this file.';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- dom_reader — what runs on every pull request
--
-- Resolves approvers and ADO group descriptors for a document. Read only, so a
-- leaked pipeline credential cannot alter anything.
-- ---------------------------------------------------------------------------
-- GRANT CONNECT needs a literal database name, which would hardcode "railway"
-- and break when this database moves in-house under a different name. Resolved
-- at runtime instead so the migration is portable.
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO dom_reader, dom_writer',
                   current_database());
END $$;

GRANT USAGE   ON SCHEMA public    TO dom_reader;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO dom_reader;

-- ---------------------------------------------------------------------------
-- dom_writer — what runs on merge
-- ---------------------------------------------------------------------------
GRANT USAGE   ON SCHEMA public    TO dom_writer;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO dom_writer;

-- Full write on the tables that record what a review cycle produced.
GRANT INSERT, UPDATE ON document_review          TO dom_writer;
GRANT INSERT, UPDATE ON document_review_approval TO dom_writer;
GRANT INSERT, UPDATE ON metric_reading           TO dom_writer;

-- Column-level UPDATE on document. This is the important restriction: closing a
-- review moves dates and status, and touches nothing else. owner_role_id,
-- published_url, repo_path, review_frequency_code, and the approver relationships
-- stay out of automation's reach.
GRANT UPDATE (last_review_date, next_review_date, status_code, updated_at)
    ON document TO dom_writer;

-- Identity sequences need USAGE for INSERT to work.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO dom_reader, dom_writer;

-- ---------------------------------------------------------------------------
-- Future tables
--
-- GRANT ... ON ALL TABLES covers only what exists right now. Without this, a
-- table created in a later migration is invisible to both service roles, and the
-- failure shows up as a permission error weeks later with no obvious cause.
--
-- Note this grants SELECT on future tables to dom_writer, not INSERT/UPDATE —
-- write access to anything new stays a deliberate decision.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO dom_reader, dom_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO dom_reader, dom_writer;

-- Views are tables for grant purposes; document_review_status needs an explicit
-- grant because it predates these roles.
GRANT SELECT ON document_review_status TO dom_reader, dom_writer;

INSERT INTO schema_migration (filename, notes)
VALUES ('014_service_role_grants.sql',
        'dom_reader (SELECT only) and dom_writer (review outcomes + column-limited document updates).');

COMMIT;
