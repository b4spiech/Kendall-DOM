-- 024_app_role_grants.sql
-- Grants for the document onboarding application.
-- Depends on: all prior migrations (grants reference the tables they created)
--
-- PREREQUISITE — run by hand BEFORE this migration. Not in this file because
-- this file is committed to git and passwords must not be:
--
--   CREATE ROLE dom_app LOGIN PASSWORD '<generate one>';
--
-- Generate with: openssl rand -base64 24
--
-- WHY INSERT ONLY
--
-- The app onboards documents. Onboarding creates records; it does not correct,
-- retire, or restructure them.
--
-- That distinction is worth enforcing rather than trusting. With INSERT only,
-- the worst a bug or a bad submission can do is add a row you can see and
-- remove. With UPDATE, a bug could silently rewrite the approvers on every
-- document in the system, and nothing would look wrong until a pull request
-- routed to the wrong person.
--
-- The cost is that the app cannot edit a submission after the fact. For now that
-- is the right trade: the pull request is the review gate, and a wrong
-- submission is closed and resubmitted rather than patched.
--
-- WHAT IT CANNOT TOUCH AT ALL
--
--   business_unit           which departments exist
--   role                    which roles exist
--   system                  which systems exist
--   role_system_identity    how roles map to ADO groups
--   every lookup table      the controlled vocabularies
--
-- These define the shape of the model. A person filling in a form should be able
-- to add a document to a department; they should not be able to invent a
-- department, a role, or a document type by typing one in. Those changes stay
-- deliberate, and stay in migrations.
--
-- NO DELETE ANYWHERE
--
-- Governance records are kept. A retired document is marked retired, not
-- removed — its review history and approval evidence are the point.

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dom_app') THEN
        RAISE EXCEPTION 'Role dom_app does not exist. Create it first — see the header of this file.';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Read everything
--
-- The form populates its dropdowns from the live model: which departments exist,
-- which roles belong to them, which ADO groups they map to, what the next
-- document number should be. All of that is reading.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO dom_app', current_database());
END $$;

GRANT USAGE  ON SCHEMA public TO dom_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dom_app;

-- ---------------------------------------------------------------------------
-- Write only what onboarding creates
-- ---------------------------------------------------------------------------
GRANT INSERT ON document            TO dom_app;
GRANT INSERT ON document_approver   TO dom_app;
GRANT INSERT ON document_reference  TO dom_app;
GRANT INSERT ON document_review     TO dom_app;

-- Processes and metrics are optional on the form. A document with no modelled
-- process is recorded as having none, rather than having one invented to fill
-- the field — but where the submitter does know, they can create it.
GRANT INSERT ON process             TO dom_app;
GRANT INSERT ON metric              TO dom_app;
GRANT INSERT ON process_metric      TO dom_app;

-- Identity columns need sequence access for INSERT to work.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO dom_app;

-- ---------------------------------------------------------------------------
-- Future tables
--
-- SELECT only. Write access to anything added later stays a deliberate decision
-- rather than something the app inherits by default.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES    TO dom_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE  ON SEQUENCES TO dom_app;

GRANT SELECT ON document_review_status TO dom_app;

INSERT INTO schema_migration (filename, notes)
VALUES ('024_app_role_grants.sql',
        'dom_app: SELECT everything, INSERT on document/approver/reference/review/process/metric. No UPDATE, no DELETE.');

COMMIT;
