-- 031_dom_mvp_process_implementation.sql
-- Adds the DOM MVP schema (24 new tables covering projects, requests, process
-- steps, activities, decisions, business rules, data entities, and
-- configuration components) and seeds the PMO Process Implementation Service:
-- 8 process steps, 51 activities, 2 problem statements, 10 requirements, and
-- 10 acceptance criteria.
-- Depends on: 001 (role, business_unit), 003 (process), 005 (metric)
--
-- SOURCE
--
-- Adapted from 20260923_001_dom_mvp_process_implementation.sql, written
-- without visibility into this repo's migration history or conventions.
-- The seed content (activity instructions, examples, rationale, requirement
-- and acceptance-criterion text) is preserved as authored -- that is the
-- actual domain knowledge this migration exists to capture, and none of it
-- is second-guessed here. What follows documents what changed structurally
-- and why.
--
-- FIXED: WOULD NOT HAVE RUN
--
-- The original assigned primary keys by hand (MAX(id)+1, via a helper
-- function) against role, business_unit, process, and schema_migration.
-- Every table in this database uses `bigint GENERATED ALWAYS AS IDENTITY`,
-- which Postgres refuses to accept an explicit value for without
-- OVERRIDING SYSTEM VALUE. The original would have failed on its first
-- INSERT. The new tables used `bigserial` instead, which does accept
-- explicit ids -- so the same pattern would have silently desynced those
-- tables' sequences from their actual max id, and the next normal insert
-- (which doesn't specify one) would collide with a manually-assigned one.
-- Fixed by using this database's standard IDENTITY column everywhere and
-- never assigning an id explicitly. The LOCK TABLE and the id-generating
-- helper function existed only to make manual assignment safe under
-- concurrency; neither is needed once nothing assigns ids by hand.
--
-- FIXED: LOOKUPS BY NAME INSTEAD OF CODE
--
-- The original resolved the PMO business unit and the PMO Manager / Project
-- Manager roles by matching on role.name / business_unit.name (with a code
-- fallback for business_unit). Every other migration in this project
-- resolves foreign keys by business code, specifically because names are
-- expected to drift and codes are the stable identifier (see the Database
-- Handbook, section 6). It happened to work here because current data
-- matches, but role_code also has a format CHECK (`^R-[0-9]{3}$`) that the
-- original's fallback role codes ('ROLE-PMO-MGR', 'ROLE-PROJ-MGR') would
-- have violated if the name match had ever missed. Fixed to resolve by
-- role_code / business_unit_code directly.
--
-- VERIFIED, NOT JUST ASSUMED: METRIC OWNERSHIP
--
-- The original drops metric.owner_role_id on the theory that a metric's
-- accountable role is inherited from its process via process_metric, and
-- does not preserve the value anywhere first. That is a real, if narrow,
-- data-loss risk: before applying it here, the only metric row with a
-- non-null owner_role_id (M-001) was checked against its linked process
-- (PROC-001) -- both resolve to role R-001 (PMO Manager). The column is
-- genuinely redundant for every row that exists today, not just assumed to
-- be. Checked against every view in the schema too -- nothing depends on it.
--
-- PROCESS OWNERSHIP: BOTH MODELS, BY REQUEST
--
-- The original replaced process.owner_role_id with four columns
-- (global/local owner/manager), dropping the original. Kept here instead:
-- owner_role_id stays exactly as it is, and the four new columns are added
-- alongside it rather than in its place. local_process_owner_role_id is
-- seeded from owner_role_id for existing rows so the two agree as a
-- starting point, but nothing about the original column changes or goes
-- away. Whatever downstream reason prefers both to coexist, this migration
-- doesn't have to be the place that forecloses it.
--
-- ADDED: MISSING FORMAT CHECKS
--
-- None of the 24 new tables had the CHECK constraint on their business-key
-- column that every other entity table in this database has. Added for the
-- six tables this file actually seeds, using the code shape their own seed
-- data establishes (e.g. activity_code ~ '^ACT-[A-Z]+-[0-9]{3}$', matching
-- 'ACT-PI-001'..'ACT-PI-051'). The other eighteen new tables (choice_set,
-- choice_value, request, decision, business_rule, data_entity,
-- data_attribute, configuration_component, and their link tables) are not
-- seeded by this migration, so there is no real code shape yet to validate
-- against -- inventing one would be a guess wearing the shape of a decision.
-- That constraint is future work, once those tables have a first real row.
--
-- FIXED: THE LEDGER INSERT ITSELF
--
-- schema_migration.id is also an IDENTITY column, and applied_at/applied_by
-- both default correctly (now() / CURRENT_USER) -- every prior migration in
-- this repo just does INSERT INTO schema_migration (filename, notes). The
-- original supplied all four columns by hand, including the same manual-id
-- pattern that broke everything else. Reverted to the two-column form.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Evolve existing Process and Metric tables
-- Verification for both changes below is in the migration header comment.
-- ---------------------------------------------------------------------------
ALTER TABLE process ADD COLUMN IF NOT EXISTS global_process_owner_role_id bigint;
ALTER TABLE process ADD COLUMN IF NOT EXISTS global_process_manager_role_id bigint;
ALTER TABLE process ADD COLUMN IF NOT EXISTS local_process_owner_role_id bigint;
ALTER TABLE process ADD COLUMN IF NOT EXISTS local_process_manager_role_id bigint;

-- owner_role_id stays. Seed local_process_owner_role_id from it as a starting
-- value for existing rows, so the two models agree until someone deliberately
-- sets the new columns to something else.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='process' AND column_name='owner_role_id') THEN
    EXECUTE 'UPDATE process SET local_process_owner_role_id = COALESCE(local_process_owner_role_id, owner_role_id)';
  END IF;
END $$;

-- Metric belongs to Process via process_metric. Role accountability is inherited from Process.
ALTER TABLE metric DROP COLUMN IF EXISTS owner_role_id CASCADE;

-- Add role foreign keys after migration of old ownership.
DO $$ BEGIN
  ALTER TABLE process ADD CONSTRAINT process_global_owner_role_fk FOREIGN KEY (global_process_owner_role_id) REFERENCES role(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE process ADD CONSTRAINT process_global_manager_role_fk FOREIGN KEY (global_process_manager_role_id) REFERENCES role(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE process ADD CONSTRAINT process_local_owner_role_fk FOREIGN KEY (local_process_owner_role_id) REFERENCES role(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE process ADD CONSTRAINT process_local_manager_role_fk FOREIGN KEY (local_process_manager_role_id) REFERENCES role(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 2. New MVP tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS choice_set (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  choice_set_code text NOT NULL UNIQUE,
  name text NOT NULL,
  purpose text,
  is_reusable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS choice_value (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  choice_value_code text NOT NULL UNIQUE,
  choice_set_id bigint NOT NULL REFERENCES choice_set(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(choice_set_id, name)
);

CREATE TABLE IF NOT EXISTS project (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_code text NOT NULL UNIQUE,
  CONSTRAINT project_code_format CHECK (project_code ~ '^PRJ-[0-9]{4}-[A-Z]+-[0-9]{3}$'),
  name text NOT NULL,
  purpose text,
  engagement_type_code text,
  project_manager_role_id bigint REFERENCES role(id),
  status_code text NOT NULL DEFAULT 'ACTIVE',
  start_date date,
  target_end_date date,
  actual_end_date date,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS request (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_code text NOT NULL UNIQUE,
  name text NOT NULL,
  intake_problem_statement text,
  business_unit_id bigint REFERENCES business_unit(id),
  proposed_bu_owner_role_id bigint REFERENCES role(id),
  proposed_process_owner_role_id bigint REFERENCES role(id),
  requested_outcome text,
  status_code text NOT NULL DEFAULT 'SUBMITTED',
  decision_code text,
  decision_reason text,
  revisit_date date,
  redirect_destination text,
  project_id bigint REFERENCES project(id),
  submitted_by text,
  submitted_at timestamptz,
  reviewed_by text,
  reviewed_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_process (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id bigint NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  process_id bigint NOT NULL REFERENCES process(id) ON DELETE CASCADE,
  relationship_type_code text NOT NULL,
  is_primary boolean NOT NULL DEFAULT false,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(project_id, process_id, relationship_type_code)
);

CREATE TABLE IF NOT EXISTS process_step (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  step_code text NOT NULL UNIQUE,
  CONSTRAINT step_code_format CHECK (step_code ~ '^PSTEP-[A-Z]+-[0-9]{3}$'),
  process_id bigint NOT NULL REFERENCES process(id) ON DELETE CASCADE,
  sequence integer NOT NULL,
  name text NOT NULL,
  purpose text,
  is_reusable boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(process_id, sequence)
);

CREATE TABLE IF NOT EXISTS activity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  activity_code text NOT NULL UNIQUE,
  CONSTRAINT activity_code_format CHECK (activity_code ~ '^ACT-[A-Z]+-[0-9]{3}$'),
  name text NOT NULL,
  purpose text,
  activity_type_code text NOT NULL CHECK (activity_type_code IN ('ACTION','DECISION','APPROVAL','REVIEW','NOTIFICATION','SYSTEM')),
  entry_criteria text,
  exit_criteria text,
  activity_instructions text,
  examples text,
  rationale text,
  is_reusable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS process_step_activity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  process_step_id bigint NOT NULL REFERENCES process_step(id) ON DELETE CASCADE,
  activity_id bigint NOT NULL REFERENCES activity(id) ON DELETE RESTRICT,
  sequence integer NOT NULL,
  is_required boolean NOT NULL DEFAULT true,
  camunda_element_id text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(process_step_id, activity_id),
  UNIQUE(process_step_id, sequence)
);

CREATE TABLE IF NOT EXISTS decision (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_code text NOT NULL UNIQUE,
  name text NOT NULL,
  purpose text,
  outcome_type_code text NOT NULL CHECK (outcome_type_code IN ('BOOLEAN','CHOICE','CLASSIFICATION','NUMERIC','TEXT')),
  choice_set_id bigint REFERENCES choice_set(id),
  is_reusable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS activity_decision (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  activity_id bigint NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
  decision_id bigint NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  sequence integer NOT NULL DEFAULT 1,
  notes text,
  UNIQUE(activity_id, decision_id)
);

CREATE TABLE IF NOT EXISTS business_rule (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_code text NOT NULL UNIQUE,
  name text NOT NULL,
  description text,
  rule_type_code text NOT NULL CHECK (rule_type_code IN ('DECISION','GOVERNANCE','APPROVAL','VALIDATION','COMPLIANCE','PROCESS')),
  definition text NOT NULL,
  example_pass text,
  example_fail text,
  rationale text,
  is_reusable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS decision_rule (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_id bigint NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  rule_id bigint NOT NULL REFERENCES business_rule(id) ON DELETE CASCADE,
  sequence integer NOT NULL DEFAULT 1,
  is_required boolean NOT NULL DEFAULT true,
  notes text,
  UNIQUE(decision_id, rule_id)
);

CREATE TABLE IF NOT EXISTS data_entity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_code text NOT NULL UNIQUE,
  name text NOT NULL,
  purpose text,
  data_owner_role_id bigint REFERENCES role(id),
  is_reusable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS data_attribute (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  attribute_code text NOT NULL UNIQUE,
  data_entity_id bigint NOT NULL REFERENCES data_entity(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  attribute_type_code text NOT NULL CHECK (attribute_type_code IN ('TEXT','BOOLEAN','INTEGER','DECIMAL','DATE','DATETIME','REFERENCE','CHOICE')),
  choice_set_id bigint REFERENCES choice_set(id),
  is_required boolean NOT NULL DEFAULT false,
  is_process_variable boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((attribute_type_code='CHOICE' AND choice_set_id IS NOT NULL) OR attribute_type_code<>'CHOICE')
);

CREATE TABLE IF NOT EXISTS process_data_entity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  process_id bigint NOT NULL REFERENCES process(id) ON DELETE CASCADE,
  data_entity_id bigint NOT NULL REFERENCES data_entity(id) ON DELETE CASCADE,
  notes text,
  UNIQUE(process_id, data_entity_id)
);

CREATE TABLE IF NOT EXISTS activity_data_entity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  activity_id bigint NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
  data_entity_id bigint NOT NULL REFERENCES data_entity(id) ON DELETE CASCADE,
  usage_type_code text NOT NULL CHECK (usage_type_code IN ('CREATES','UPDATES','CONSUMES')),
  notes text,
  UNIQUE(activity_id, data_entity_id, usage_type_code)
);

CREATE TABLE IF NOT EXISTS problem_statement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  problem_code text NOT NULL UNIQUE,
  CONSTRAINT problem_code_format CHECK (problem_code ~ '^PROB-[A-Z]+-[0-9]{3}$'),
  project_id bigint NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NOT NULL,
  problem_level_code text NOT NULL CHECK (problem_level_code IN ('PRIMARY','SECONDARY')),
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_problem_one_primary_per_project
  ON problem_statement(project_id) WHERE problem_level_code='PRIMARY' AND is_active;

CREATE TABLE IF NOT EXISTS requirement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  requirement_code text NOT NULL UNIQUE,
  CONSTRAINT requirement_code_format CHECK (requirement_code ~ '^REQ-[A-Z]+-[0-9]{3}$'),
  name text NOT NULL,
  description text NOT NULL,
  requirement_type_code text NOT NULL CHECK (requirement_type_code IN ('MUST','SHOULD')),
  is_reusable boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS problem_requirement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  problem_statement_id bigint NOT NULL REFERENCES problem_statement(id) ON DELETE CASCADE,
  requirement_id bigint NOT NULL REFERENCES requirement(id) ON DELETE CASCADE,
  notes text,
  UNIQUE(problem_statement_id, requirement_id)
);

CREATE TABLE IF NOT EXISTS acceptance_criterion (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  acceptance_criterion_code text NOT NULL UNIQUE,
  CONSTRAINT acceptance_criterion_code_format CHECK (acceptance_criterion_code ~ '^AC-[A-Z]+-[0-9]{3}$'),
  requirement_id bigint NOT NULL REFERENCES requirement(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NOT NULL,
  criterion_type_code text NOT NULL CHECK (criterion_type_code IN ('OBSERVATION','MEASUREMENT','REPORT','VALIDATION','SYSTEM')),
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS configuration_component (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  configuration_component_code text NOT NULL UNIQUE,
  name text NOT NULL,
  purpose text,
  system_id bigint REFERENCES system(id),
  configuration_reference text,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS configuration_component_requirement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  configuration_component_id bigint NOT NULL REFERENCES configuration_component(id) ON DELETE CASCADE,
  requirement_id bigint NOT NULL REFERENCES requirement(id) ON DELETE CASCADE,
  notes text,
  UNIQUE(configuration_component_id, requirement_id)
);

CREATE TABLE IF NOT EXISTS configuration_component_activity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  configuration_component_id bigint NOT NULL REFERENCES configuration_component(id) ON DELETE CASCADE,
  activity_id bigint NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
  notes text,
  UNIQUE(configuration_component_id, activity_id)
);

CREATE TABLE IF NOT EXISTS configuration_component_data_entity (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  configuration_component_id bigint NOT NULL REFERENCES configuration_component(id) ON DELETE CASCADE,
  data_entity_id bigint NOT NULL REFERENCES data_entity(id) ON DELETE CASCADE,
  usage_type_code text NOT NULL CHECK (usage_type_code IN ('USES','MODIFIES','CREATES')),
  notes text,
  UNIQUE(configuration_component_id, data_entity_id, usage_type_code)
);

-- ---------------------------------------------------------------------------
-- 3. Supporting indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_process_step_process ON process_step(process_id, sequence);
CREATE INDEX IF NOT EXISTS ix_psa_step_sequence ON process_step_activity(process_step_id, sequence);
CREATE INDEX IF NOT EXISTS ix_problem_project ON problem_statement(project_id);
CREATE INDEX IF NOT EXISTS ix_ac_requirement ON acceptance_criterion(requirement_id);
CREATE INDEX IF NOT EXISTS ix_request_status ON request(status_code);
CREATE INDEX IF NOT EXISTS ix_project_status ON project(status_code);

-- ---------------------------------------------------------------------------
-- 4. Seed prerequisites in existing tables
-- Resolved by business code, not name -- see header. PMO, R-001 (PMO
-- Manager), and R-003 (Project Manager) already exist (migrations 001-023),
-- so this is expected to find rows, not create them.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_bu bigint; v_pmo bigint; v_pm bigint;
BEGIN
  SELECT id INTO v_bu FROM business_unit WHERE business_unit_code = 'PMO';
  IF v_bu IS NULL THEN
    INSERT INTO business_unit(business_unit_code,name,is_active,notes)
    VALUES('PMO','Program Management Office',true,'Created by DOM MVP migration')
    RETURNING id INTO v_bu;
  END IF;

  SELECT id INTO v_pmo FROM role WHERE role_code = 'R-001';
  IF v_pmo IS NULL THEN
    INSERT INTO role(role_code,name,role_type,purpose,responsibility_summary,approval_authority,is_active,business_unit_id)
    VALUES('R-001','PMO Manager','Process Owner','Govern and change-control PMO processes','Owns PMO process standards and governance','Approves PMO process changes',true,v_bu)
    RETURNING id INTO v_pmo;
  END IF;

  SELECT id INTO v_pm FROM role WHERE role_code = 'R-003';
  IF v_pm IS NULL THEN
    INSERT INTO role(role_code,name,role_type,purpose,responsibility_summary,approval_authority,is_active,business_unit_id)
    VALUES('R-003','Project Manager','Process Manager','Run Process Implementation engagements','Responsible for day-to-day execution and performance',NULL,true,v_bu)
    RETURNING id INTO v_pm;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Seed Process, Project, and relationship
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_bu bigint; v_owner bigint; v_mgr bigint; v_process bigint; v_project bigint;
BEGIN
  SELECT id INTO v_bu FROM business_unit WHERE business_unit_code = 'PMO';
  SELECT id INTO v_owner FROM role WHERE role_code = 'R-001';
  SELECT id INTO v_mgr FROM role WHERE role_code = 'R-003';

  SELECT id INTO v_process FROM process WHERE process_code='PROC-003';
  IF v_process IS NULL THEN
    INSERT INTO process(process_code,name,purpose,owner_role_id,local_process_owner_role_id,local_process_manager_role_id,is_active,notes,business_unit_id)
    VALUES('PROC-003','PMO Process Implementation Service','Help business units establish project-related processes addressing cost, schedule, project-process quality, governance, prioritization, resource planning, and work management.',v_owner,v_owner,v_mgr,true,'Seeded by DOM MVP migration',v_bu)
    RETURNING id INTO v_process;
  ELSE
    UPDATE process SET owner_role_id=COALESCE(owner_role_id,v_owner), local_process_owner_role_id=COALESCE(local_process_owner_role_id,v_owner), local_process_manager_role_id=COALESCE(local_process_manager_role_id,v_mgr), updated_at=now() WHERE id=v_process;
  END IF;

  INSERT INTO project(project_code,name,purpose,engagement_type_code,project_manager_role_id,status_code,start_date,notes)
  VALUES('PRJ-2026-PI-001','Implement PMO Process Implementation Service','Establish the governed PMO Process Implementation Service.','PROCESS_IMPLEMENTATION',v_owner,'ACTIVE',DATE '2026-09-23','Synthetic MVP validation Project')
  RETURNING id INTO v_project;

  INSERT INTO project_process(project_id,process_id,relationship_type_code,is_primary,notes)
  VALUES(v_project,v_process,'ESTABLISHES',true,'The Project establishes the Process Implementation Service.');
END $$;

-- ---------------------------------------------------------------------------
-- 6. Seed Process Steps
-- ---------------------------------------------------------------------------
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-001',p.id,1,'Receive and Qualify Request','Determine whether PMO should accept, defer, redirect, or decline a request.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-002',p.id,2,'Understand Current State','Develop a factual understanding of published and actual process execution.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-003',p.id,3,'Define Requirements','Define the primary problem, requirements, and acceptance criteria.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-004',p.id,4,'Design Future State','Collaboratively design the future process, information model, tool strategy, and SOW.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-005',p.id,5,'Configure the Solution','Implement and document the approved design.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-006',p.id,6,'Validate with Real Work','Validate Must requirements and acceptance criteria using realistic scenarios.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-007',p.id,7,'Go Live and Hand Off','Publish documentation, train users, activate the process, and transfer ownership.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();
INSERT INTO process_step(step_code,process_id,sequence,name,purpose,is_reusable,is_active)
SELECT 'PSTEP-PI-008',p.id,8,'Stabilize and Close','Confirm stable operation, capture learning, and close the Project.',false,true FROM process p WHERE p.process_code='PROC-003'
ON CONFLICT(step_code) DO UPDATE SET sequence=EXCLUDED.sequence,name=EXCLUDED.name,purpose=EXCLUDED.purpose,updated_at=now();

-- ---------------------------------------------------------------------------
-- 7. Seed Activities and Step memberships
-- ---------------------------------------------------------------------------

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-001',$dom$Receive Request$dom$,$dom$Create the intake record when a requester submits a process implementation request.$dom$,'SYSTEM',$dom$Requester submits required intake information.$dom$,$dom$Request exists with Status = Submitted.$dom$,$dom$Capture the title, problem statement, business unit, proposed owners, requested outcome, requester, and timestamp; assign a code; set Submitted; preserve the original wording.$dom$,$dom$A bid-deadline problem is recorded exactly as submitted.$dom$,$dom$Separates request receipt from active review.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-001' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-002',$dom$Begin Review$dom$,$dom$Start PMO review of a Submitted Request.$dom$,'ACTION',$dom$PMO Manager opens a Submitted Request.$dom$,$dom$Status = Under Review.$dom$,$dom$Open the Request; assign review responsibility; set Under Review; inspect submitted fields without making a decision.$dom$,$dom$A Monday submission stays Submitted until opened Tuesday.$dom$,$dom$Distinguishes received demand from active work.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-002' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-003',$dom$Verify Required Information$dom$,$dom$Confirm enough information exists to screen the Request.$dom$,'REVIEW',$dom$Request is Under Review.$dom$,$dom$Ready for screening or Pending Information.$dom$,$dom$Verify problem statement, business unit, proposed BU Owner, proposed Process Owner, and requested outcome; request missing information; set Pending Information until received.$dom$,$dom$“Need help” with blank owners is held Pending Information.$dom$,$dom$Prevents PMO from guessing.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-003' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-004',$dom$Screen Request$dom$,$dom$Determine whether the Request fits the PMO Process Implementation Service.$dom$,'ACTION',$dom$Minimum information is available.$dom$,$dom$Screening tests have recorded results.$dom$,$dom$Test process-solvability, PMO scope, capacity, existing solution, duplicate work, and ownership; record the disposition.$dom$,$dom$Warehouse receiving redirects to CI/OPEX; bid tracking passes.$dom$,$dom$Avoids unnecessary approvals and scope mismatch.$dom$,false,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-004' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-005',$dom$Validate Owners$dom$,$dom$Confirm nominated BU and Process Owner roles are appropriate.$dom$,'REVIEW',$dom$Request contains proposed owners.$dom$,$dom$Correct approver roles are recorded.$dom$,$dom$Verify resource authority and process-outcome accountability; classify local/global context; correct owner roles directly; require global approval for a global standard or pilot.$dom$,$dom$Replace an SME with the role accountable for the outcome.$dom$,$dom$Ensures authority and accountability without administrative churn.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-005' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-006',$dom$Obtain Approvals$dom$,$dom$Obtain business commitment for the implementation.$dom$,'APPROVAL',$dom$Request passes screening.$dom$,$dom$All required responses are recorded.$dom$,$dom$Set Awaiting Approval; route BU and Process Owner approvals in parallel; explain resource commitment; allow Approve or Decline only; never override Decline.$dom$,$dom$BU Owner commits resources and Global Process Owner approves a pilot.$dom$,$dom$Confirms real commitment before PMO invests capacity.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,6,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-006' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-007',$dom$Issue Decision$dom$,$dom$Record the official Request disposition.$dom$,'DECISION',$dom$Screening or approvals are complete.$dom$,$dom$Accepted, Deferred, Redirected, or Declined is recorded.$dom$,$dom$Apply rules; record date and reason; require Revisit Date for Deferred and destination for Redirected; do not override rule-driven outcomes.$dom$,$dom$No capacity produces Deferred; a required decline produces Declined.$dom$,$dom$Creates consistent, auditable decisions.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,7,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-007' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-008',$dom$Create Project$dom$,$dom$Create a Process Implementation Project after acceptance.$dom$,'SYSTEM',$dom$Decision = Accepted.$dom$,$dom$Project exists and is linked to Request.$dom$,$dom$Create from the Process Implementation template; set engagement type; copy approved intake information; link Request; require no additional approval.$dom$,$dom$Accepted bid-management request creates a Project.$dom$,$dom$Acceptance already satisfies creation conditions.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,8,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-008' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-009',$dom$Notify Requester$dom$,$dom$Communicate the Request disposition.$dom$,'NOTIFICATION',$dom$Decision is recorded.$dom$,$dom$Requester has been notified.$dom$,$dom$Send the decision and relevant details: Project for Accepted, Revisit Date for Deferred, destination for Redirected, reason for Declined.$dom$,$dom$Deferred notice includes Capacity Constraint and revisit date.$dom$,$dom$Provides closure and next-step clarity.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,9,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-009' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-010',$dom$Close or Retain Request$dom$,$dom$Apply the correct terminal or continuing Request state.$dom$,'SYSTEM',$dom$Requester has been notified.$dom$,$dom$Request is closed, linked, or retained Deferred.$dom$,$dom$Link Accepted to Project; close Redirected/Declined; retain Deferred open; never auto-reopen on revisit date.$dom$,$dom$Deferred stays open until PMO actively reopens it.$dom$,$dom$Preserves lifecycle integrity.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,10,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-010' WHERE ps.step_code='PSTEP-PI-001'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-011',$dom$Establish Discovery Scope$dom$,$dom$Define current-state analysis boundaries.$dom$,'ACTION',$dom$Project enters Step 2.$dom$,$dom$Discovery Scope Definition exists.$dom$,$dom$Identify process, boundaries, local/global context, affected units, owners, participants, variants, and available documentation; do not require separate approval to begin.$dom$,$dom$Scope identifies which bid-process variants are included.$dom$,$dom$Prevents accidental mixing of processes and locations.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-011' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-012',$dom$Review Existing Documentation$dom$,$dom$Understand the Published Process.$dom$,'REVIEW',$dom$Discovery scope and sources are known.$dom$,$dom$Published Process is defined or absence recorded.$dom$,$dom$Collect SOPs, maps, work instructions, forms, templates, and system documentation; record documented flow; note conflicts; continue if none exists.$dom$,$dom$SOP says all bids enter a tracker within one day.$dom$,$dom$Creates a documented baseline without confusing it with reality.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-012' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-013',$dom$Conduct Interviews$dom$,$dom$Understand participant descriptions, variants, pain points, and bottlenecks.$dom$,'ACTION',$dom$Participants are identified and documents reviewed.$dom$,$dom$Interview findings are captured.$dom$,$dom$Prepare questions; interview owners, performers, supervisors, and stakeholders; capture actual work, decisions, handoffs, workarounds, shadow systems, pain points, bottlenecks, and contradictions.$dom$,$dom$One estimator uses a shared tracker; another uses a spreadsheet.$dom$,$dom$Exposes differing mental models before mapping.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-013' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-014',$dom$Observe Work$dom$,$dom$Document actual process execution.$dom$,'ACTION',$dom$Representative work is available.$dom$,$dom$Observed activities and workarounds are documented.$dom$,$dom$Observe normal and exception scenarios; record sequence, systems, decisions, handoffs, approvals, delays, and shadow tools; avoid blame.$dom$,$dom$Email submissions are observed despite a form requirement.$dom$,$dom$Reduces reliance on expectations and self-reporting.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-014' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-015',$dom$Analyze Available Data$dom$,$dom$Use available data to support or challenge findings.$dom$,'ACTION',$dom$Relevant data is available.$dom$,$dom$Current-state data findings or limitations are recorded.$dom$,$dom$Review missed deadlines, backlog, errors, rework, and queues; compare with interviews and observations; record quality limits; do not require CI-level timing unless tailored.$dom$,$dom$Deadline and queue data support a prioritization problem.$dom$,$dom$Strengthens findings without unnecessary analysis.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-015' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-016',$dom$Document Current State Process$dom$,$dom$Synthesize actual execution into an authoritative current-state model.$dom$,'ACTION',$dom$Discovery evidence is sufficiently complete.$dom$,$dom$Current State Process, map, pain points, bottlenecks, observations, and variances exist.$dom$,$dom$Map actual trigger-to-output flow; include roles, systems, inputs, outputs, approvals, decisions, handoffs, variants, pain points, and bottlenecks; compare to published process; exclude future-state ideas.$dom$,$dom$Actual map includes email, personal spreadsheets, weekly review, and later tracker entry.$dom$,$dom$Provides the factual baseline for requirements.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,6,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-016' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-017',$dom$Review Current State Findings$dom$,$dom$Check factual accuracy and collect context without seeking approval.$dom$,'REVIEW',$dom$Current-state findings are documented.$dom$,$dom$Supported corrections are incorporated.$dom$,$dom$Review findings with owner and stakeholders; request factual corrections and context; require support; retain supported observations that differ from expectations; record unresolved conflicts.$dom$,$dom$Observed email intake remains despite owner expectation of form use.$dom$,$dom$Protects objectivity while correcting genuine errors.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,7,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-017' WHERE ps.step_code='PSTEP-PI-002'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-018',$dom$Refine Problem Statement$dom$,$dom$Create an evidence-based Primary Problem Statement.$dom$,'ACTION',$dom$Step 2 findings are complete.$dom$,$dom$One Primary and justified Secondary statements exist.$dom$,$dom$Review intake and current state; separate solution language; draft one Primary statement; add Secondary statements only when justified; avoid design language.$dom$,$dom$“Need a bid tracker” becomes a visibility and prioritization problem.$dom$,$dom$Anchors the Project and prevents wish-list requirements.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-018' WHERE ps.step_code='PSTEP-PI-003'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-019',$dom$Define Requirements$dom$,$dom$Define solution-neutral capabilities needed to solve the problem.$dom$,'ACTION',$dom$Problem Statements and findings exist.$dom$,$dom$Candidate Requirements are traceable.$dom$,$dom$Convert findings to capability statements; remove tool wording; link each Requirement to a Problem Statement; reject or park unsupported requests; check collective coverage.$dom$,$dom$Use “identify bids due within seven days,” not “build a dashboard.”$dom$,$dom$Controls scope while preserving design flexibility.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-019' WHERE ps.step_code='PSTEP-PI-003'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-020',$dom$Classify Requirements$dom$,$dom$Classify Requirements as Must or Should.$dom$,'DECISION',$dom$Candidate Requirements are traceable.$dom$,$dom$Every Requirement has a classification.$dom$,$dom$Ask whether removing the Requirement leaves the Primary Problem unsolved; classify Must if yes, otherwise Should when helpful; do not justify Must solely from a Secondary Problem.$dom$,$dom$Due-date visibility is Must; reminders may be Should.$dom$,$dom$Creates a defensible essential-versus-helpful boundary.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-020' WHERE ps.step_code='PSTEP-PI-003'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-021',$dom$Define Acceptance Criteria$dom$,$dom$Define proof that each Requirement is satisfied.$dom$,'ACTION',$dom$Requirements are classified.$dom$,$dom$Every Requirement has one or more criteria.$dom$,$dom$Write observable or measurable conditions; avoid restatement; ensure Step 6 testability; link directly to Requirement.$dom$,$dom$User can produce a complete seven-day due list without personal spreadsheets.$dom$,$dom$Eliminates subjective acceptance.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-021' WHERE ps.step_code='PSTEP-PI-003'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-022',$dom$Review Requirement Traceability$dom$,$dom$Confirm the chain from Problem Statement through Acceptance Criteria.$dom$,'REVIEW',$dom$Problem Statements, Requirements, and criteria exist.$dom$,$dom$Traceability gaps are corrected.$dom$,$dom$Confirm one Primary Problem; every Requirement links to a Problem; every Must supports the Primary; every Requirement has criteria; remove duplicates, gaps, and solution wording.$dom$,$dom$Unsupported mobile-app Requirement is removed.$dom$,$dom$Prevents scope creep before design.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-022' WHERE ps.step_code='PSTEP-PI-003'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-023',$dom$Facilitate Future State Design$dom$,$dom$Collaboratively design the future process.$dom$,'ACTION',$dom$Approved problems, requirements, criteria, and current state exist.$dom$,$dom$Stakeholders converge on one design.$dom$,$dom$Review the Primary Problem, Musts, and findings; workshop approaches; evaluate options informally; converge on one future state; document key decisions and constraints.$dom$,$dom$Team selects one bid intake and prioritization flow.$dom$,$dom$Uses stakeholder knowledge and builds ownership.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-023' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-024',$dom$Document Future State Process$dom$,$dom$Create the authoritative Future State Process and map.$dom$,'ACTION',$dom$Stakeholders have converged.$dom$,$dom$Future State Process exists with Requirement traceability.$dom$,$dom$Map activities, sequencing, decisions, approvals, roles, handoffs, and exceptions; link activities to Requirements; verify all Musts; remove unsupported steps; defer tool configuration.$dom$,$dom$Review Upcoming Bid Queue realizes due-date visibility.$dom$,$dom$Creates a need-driven design.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-024' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-025',$dom$Define Future State Information Model$dom$,$dom$Identify information required for operation.$dom$,'ACTION',$dom$Future State Process is defined.$dom$,$dom$Entities, attributes, owners, sources, producers, and consumers exist.$dom$,$dom$Review each Activity; identify created/updated/consumed entities; define attributes and types; assign data ownership and sources; remove inaccessible or unjustified data.$dom$,$dom$Approval has Approver, Decision, and Decision Date.$dom$,$dom$Prevents tools from dictating business information.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-025' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-026',$dom$Assign Process Responsibilities$dom$,$dom$Define governance, operation, and measurement responsibilities.$dom$,'ACTION',$dom$Future activities and roles are known.$dom$,$dom$Activity responsibilities and Process ownership are recorded.$dom$,$dom$Assign responsible roles to Activities; confirm owner/manager roles; inherit ownership below Process; relate Metrics to Process; populate local/global roles only when applicable.$dom$,$dom$PMO Manager controls change; Project Managers run the process.$dom$,$dom$Separates governance from operation.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-026' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-027',$dom$Select Tool Strategy$dom$,$dom$Select the technology approach supporting the design.$dom$,'DECISION',$dom$Future Process and Information Model exist.$dom$,$dom$One Tool Strategy is recorded.$dom$,$dom$Determine whether technology is needed; evaluate approved platforms; confirm data access; identify IS dependencies; select the strategy and rationale.$dom$,$dom$Select Process Change Only when procedure and a register suffice.$dom$,$dom$Enforces process-before-tool.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-027' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-028',$dom$Generate Final SOW$dom$,$dom$Assemble the implementation baseline from approved DOM knowledge.$dom$,'SYSTEM',$dom$Design, requirements, criteria, information, and tool strategy are approved.$dom$,$dom$Draft versioned SOW exists.$dom$,$dom$Retrieve approved source objects; assemble the standard SOW; preserve identifiers/version metadata; do not independently rewrite facts.$dom$,$dom$Generator inserts approved Problem Statement and Musts.$dom$,$dom$Reduces duplicate truth and manual reauthoring.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,6,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-028' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-029',$dom$Release Final SOW$dom$,$dom$Release the generated SOW as the controlled baseline.$dom$,'ACTION',$dom$Draft SOW exists.$dom$,$dom$Released versioned SOW exists.$dom$,$dom$Review rendering/completeness; confirm scope traceability; correct source objects and regenerate; release; govern later changes.$dom$,$dom$Missing Requirement is fixed in DOM, then regenerated.$dom$,$dom$Keeps DOM authoritative.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,7,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-029' WHERE ps.step_code='PSTEP-PI-004'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-030',$dom$Configure Solution$dom$,$dom$Implement the approved design.$dom$,'ACTION',$dom$Released SOW and design package exist.$dom$,$dom$Solution is configured for review.$dom$,$dom$Configure workflows, forms, data, views, access, reports, and approved automations; collaborate with business while PMO owns configuration; implement only approved design; document components; route custom work to IS.$dom$,$dom$PMO configures Request Form and approval workflow.$dom$,$dom$Transforms design into a controlled working solution.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-030' WHERE ps.step_code='PSTEP-PI-005'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-031',$dom$Document Configuration Component$dom$,$dom$Record impact-analysis metadata for configured elements.$dom$,'ACTION',$dom$A configuration element exists.$dom$,$dom$Configuration Component record is complete.$dom$,$dom$Assign code/name; identify System; link Requirements, Activities, and Data Entities; record Config ID or artifact; keep detailed settings in linked documentation unless atomic storage is justified.$dom$,$dom$Approval Workflow links to Approval Activity, entity, Requirement, and Camunda ID.$dom$,$dom$Supports impact analysis without overloading the DOM.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-031' WHERE ps.step_code='PSTEP-PI-005'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-032',$dom$Review Configuration Against Design$dom$,$dom$Confirm configuration matches approved design.$dom$,'REVIEW',$dom$Components and solution are available.$dom$,$dom$Gaps are identified or solution is validation-ready.$dom$,$dom$Review Musts and supporting components; verify activities, entities, attributes, tool strategy, and SOW; identify missing, extra, or inconsistent configuration; separate defects from design changes.$dom$,$dom$Missing status field is a gap; unapproved mobile feature is removed.$dom$,$dom$Proves the team built what was designed.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-032' WHERE ps.step_code='PSTEP-PI-005'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-033',$dom$Correct Configuration Gap$dom$,$dom$Resolve an in-scope configuration defect.$dom$,'ACTION',$dom$A gap is identified.$dom$,$dom$Corrected component is ready for re-review.$dom$,$dom$Confirm defect versus design change; correct; update documentation; recheck traceability; return design changes to governance.$dom$,$dom$Add missing Due Date field required by the model.$dom$,$dom$Maintains alignment without silent redesign.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-033' WHERE ps.step_code='PSTEP-PI-005'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-034',$dom$Prepare Validation Environment$dom$,$dom$Prepare users, access, data, scenarios, and test references.$dom$,'ACTION',$dom$Configuration review is complete.$dom$,$dom$Validation setup is ready.$dom$,$dom$Confirm environment and access; prepare representative data/scenarios; translate criteria into ADO tests; identify validators; confirm issue recording.$dom$,$dom$Load representative bids for due-date tests.$dom$,$dom$Prevents setup problems from appearing as solution failures.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-034' WHERE ps.step_code='PSTEP-PI-005'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-035',$dom$Execute Validation Scenario$dom$,$dom$Have real users exercise realistic scenarios.$dom$,'ACTION',$dom$Environment, users, scenarios, and criteria are ready.$dom$,$dom$Execution result exists.$dom$,$dom$Validator follows the scenario; observe without coaching around defects; record results in ADO; capture unexpected behavior; preserve Requirement traceability.$dom$,$dom$Bid coordinator retrieves all bids due within seven days.$dom$,$dom$Proves practical use, not feature existence.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-035' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-036',$dom$Record Validation Result$dom$,$dom$Record Requirement and criterion satisfaction.$dom$,'ACTION',$dom$Scenario executed.$dom$,$dom$Requirement-level result and ADO reference exist.$dom$,$dom$Record each criterion pass/fail; link Requirement and ADO execution; capture concise evidence; keep detailed logs in ADO.$dom$,$dom$REQ-PI-005 links to ADO test run 123.$dom$,$dom$Maintains traceability without duplicating test management.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-036' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-037',$dom$Classify Validation Finding$dom$,$dom$Classify failed or unexpected findings.$dom$,'DECISION',$dom$Validation issue exists.$dom$,$dom$Finding is classified.$dom$,$dom$Classify Must Failure, Should Failure, Configuration Defect, Data Issue, Training Issue, or Enhancement Request; do not treat enhancements as defects; route through governance.$dom$,$dom$New mobile view request is Enhancement, not defect.$dom$,$dom$Protects go-live logic and scope.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-037' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-038',$dom$Correct Validation Defect$dom$,$dom$Correct an approved in-scope defect.$dom$,'ACTION',$dom$Finding is a correctable defect.$dom$,$dom$Corrected item is ready for retest.$dom$,$dom$Confirm scope; correct component/data; update documentation; identify impacts; retest criteria.$dom$,$dom$Fix incorrect overdue-date comparison.$dom$,$dom$Closes validation gaps with traceability.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-038' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-039',$dom$Review Validation Results$dom$,$dom$Determine whether approved Requirements are satisfied.$dom$,'REVIEW',$dom$Testing and retesting are sufficiently complete.$dom$,$dom$Consolidated Requirement-level readiness exists.$dom$,$dom$Review Must/Should results; confirm Must pass or governed exceptions; review findings; confirm evidence; identify additional testing.$dom$,$dom$All Musts pass; one Should is deferred.$dom$,$dom$Keeps focus on solving the primary problem.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-039' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-040',$dom$Issue Go-Live Recommendation$dom$,$dom$Record whether the solution is ready for deployment.$dom$,'DECISION',$dom$Validation results reviewed.$dom$,$dom$Ready or Not Ready recommendation exists.$dom$,$dom$Confirm Musts and criteria; confirm remaining issues resolved/accepted; select recommendation; record rationale and prerequisites.$dom$,$dom$All Musts pass and deferred Should does not block go-live.$dom$,$dom$Creates an evidence-based transition decision.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,6,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-040' WHERE ps.step_code='PSTEP-PI-006'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-041',$dom$Publish Process Documentation$dom$,$dom$Make governed documentation available.$dom$,'ACTION',$dom$Ready recommendation and approved documents exist.$dom$,$dom$Required documents are Published and accessible.$dom$,$dom$Identify required materials; generate/update from DOM; publish to governed target; verify access; record metadata.$dom$,$dom$Publish step SOP and training guide.$dom$,$dom$Provides authoritative reference after handoff.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-041' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-042',$dom$Train Required Users$dom$,$dom$Prepare required users for the process and tools.$dom$,'ACTION',$dom$Training materials and production-ready solution exist.$dom$,$dom$Training is delivered and completion evidence exists.$dom$,$dom$Identify roles; train on process, responsibilities, tools, and documentation; use scenarios; record completion; capture gaps.$dom$,$dom$Project Managers practice screening a sample Request.$dom$,$dom$Users must be able to execute the new process.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-042' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-043',$dom$Verify User Capability$dom$,$dom$Confirm users can perform critical work.$dom$,'REVIEW',$dom$Training delivered.$dom$,$dom$Capability is demonstrated or remediation assigned.$dom$,$dom$Have representative users complete critical tasks; compare to instructions and criteria; identify gaps; remediate; record evidence outside person-level DOM detail.$dom$,$dom$Project Manager routes a sample without coaching.$dom$,$dom$Attendance alone does not prove readiness.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-043' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-044',$dom$Activate Production Process$dom$,$dom$Make the solution operational.$dom$,'SYSTEM',$dom$Go-live prerequisites are satisfied.$dom$,$dom$Production process is active.$dom$,$dom$Activate production components; verify access and critical dependencies; confirm forms/workflows/views; update MVP active state; record timestamp.$dom$,$dom$Request Form and screening workflow are activated.$dom$,$dom$Creates a clear cutover point.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-044' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-045',$dom$Accept Process Ownership$dom$,$dom$Transfer ongoing governance and operation.$dom$,'APPROVAL',$dom$Production is active, documentation published, users capable.$dom$,$dom$Ownership acceptance is recorded.$dom$,$dom$Review governance with Owner and operations/metrics with Manager; confirm references; record acceptance; exclude unsupported scope or defects.$dom$,$dom$PMO Manager accepts change control and PMs accept daily operation.$dom$,$dom$Clarifies permanent responsibility after delivery.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-045' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-046',$dom$Notify Go-Live$dom$,$dom$Communicate live status and authoritative resources.$dom$,'NOTIFICATION',$dom$Activation and ownership acceptance complete.$dom$,$dom$Stakeholders have received communication.$dom$,$dom$Announce effective date; identify owner/manager roles; link documentation and solution; explain stabilization channel; do not invent instructions in the message.$dom$,$dom$Launch notice includes SOP and issue route.$dom$,$dom$Ensures users know the standard and support path.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,6,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-046' WHERE ps.step_code='PSTEP-PI-007'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-047',$dom$Monitor Stabilization$dom$,$dom$Observe early operation and critical issues.$dom$,'ACTION',$dom$Process is live and Project is stabilizing.$dom$,$dom$Usage, issues, and ownership are reviewed for closure.$dom$,$dom$Monitor use, access, critical issues, adoption signals, and metric availability; confirm ownership; separate defects and enhancements; continue for the defined period.$dom$,$dom$Requests enter the workflow with no critical routing failures.$dom$,$dom$Reveals issues not seen in controlled tests.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,1,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-047' WHERE ps.step_code='PSTEP-PI-008'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-048',$dom$Resolve Critical Issue$dom$,$dom$Resolve or formally accept a critical stabilization issue.$dom$,'ACTION',$dom$Critical issue identified.$dom$,$dom$Issue resolved, accepted, or escalated.$dom$,$dom$Assess operational and Must impact; classify; correct/retest defects; govern design changes; record acceptance if not corrected.$dom$,$dom$Fix production permission blocking PMs.$dom$,$dom$Prevents closure while the process cannot operate.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,2,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-048' WHERE ps.step_code='PSTEP-PI-008'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-049',$dom$Capture Lessons Learned$dom$,$dom$Preserve learning for future implementations.$dom$,'ACTION',$dom$Stabilization has occurred.$dom$,$dom$Lessons are recorded.$dom$,$dom$Review success and rework; identify reusable practices, templates, rules, and patterns; record as Project knowledge; route methodology changes through Process Owner.$dom$,$dom$Observation was more useful than interviews alone.$dom$,$dom$Improves future work without silent process change.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,3,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-049' WHERE ps.step_code='PSTEP-PI-008'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-050',$dom$Record Improvement Idea$dom$,$dom$Capture follow-on ideas without expanding the Project.$dom$,'ACTION',$dom$Enhancement identified.$dom$,$dom$Idea is stored for future review.$dom$,$dom$Describe need; link relevant Process/component; do not auto-create Project/Request; preserve context; use future Improvement Candidate workflow when available.$dom$,$dom$Automated reminders are recorded for later review.$dom$,$dom$Supports continuous improvement without scope creep.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,4,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-050' WHERE ps.step_code='PSTEP-PI-008'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

INSERT INTO activity(activity_code,name,purpose,activity_type_code,entry_criteria,exit_criteria,activity_instructions,examples,rationale,is_reusable,is_active)
VALUES('ACT-PI-051',$dom$Close Project$dom$,$dom$Close delivery while leaving the Process operational.$dom$,'SYSTEM',$dom$Stable operation, accepted issues, lessons, and ownership are confirmed.$dom$,$dom$Project is Closed and Process remains active.$dom$,$dom$Verify stabilization; confirm residual items recorded; confirm ownership/docs/configuration/metrics continue; set actual end and Closed; preserve relationships.$dom$,$dom$Project closes while Process and Metrics remain active.$dom$,$dom$Separates temporary delivery from permanent operation.$dom$,true,true)
ON CONFLICT(activity_code) DO UPDATE SET name=EXCLUDED.name,purpose=EXCLUDED.purpose,activity_type_code=EXCLUDED.activity_type_code,entry_criteria=EXCLUDED.entry_criteria,exit_criteria=EXCLUDED.exit_criteria,activity_instructions=EXCLUDED.activity_instructions,examples=EXCLUDED.examples,rationale=EXCLUDED.rationale,is_reusable=EXCLUDED.is_reusable,is_active=true,updated_at=now();
INSERT INTO process_step_activity(process_step_id,activity_id,sequence,is_required)
SELECT ps.id,a.id,5,true FROM process_step ps JOIN activity a ON a.activity_code='ACT-PI-051' WHERE ps.step_code='PSTEP-PI-008'
ON CONFLICT(process_step_id,activity_id) DO UPDATE SET sequence=EXCLUDED.sequence,updated_at=now();

-- ---------------------------------------------------------------------------
-- 8. Seed core Project traceability
-- ---------------------------------------------------------------------------
INSERT INTO problem_statement(problem_code,project_id,name,description,problem_level_code,notes)
SELECT 'PROB-PI-001',p.id,'Business Units Lack a Repeatable Process Implementation Method',
       'Business units need right-sized project and work-management processes, but PMO lacks a standardized service for discovering, designing, configuring, validating, and handing off those processes.',
       'PRIMARY','Synthetic MVP validation data'
FROM project p WHERE p.project_code='PRJ-2026-PI-001'
ON CONFLICT(problem_code) DO UPDATE SET description=EXCLUDED.description,updated_at=now();

INSERT INTO problem_statement(problem_code,project_id,name,description,problem_level_code,notes)
SELECT 'PROB-PI-002',p.id,'Process Knowledge Is Distributed',
       'Process rules, roles, requirements, data definitions, configuration information, examples, and rationale are not consistently related in a governed operating model.',
       'SECONDARY','Synthetic MVP validation data'
FROM project p WHERE p.project_code='PRJ-2026-PI-001'
ON CONFLICT(problem_code) DO UPDATE SET description=EXCLUDED.description,updated_at=now();

INSERT INTO requirement(requirement_code,name,description,requirement_type_code,is_reusable)
VALUES
('REQ-PI-001','Screen Requests Before Approval','PMO must complete required screening before requesting business approvals.','MUST',false),
('REQ-PI-002','Require Business Commitment','The service must obtain BU Owner and Process Owner commitments before acceptance.','MUST',false),
('REQ-PI-003','Document Actual Current State','The service must document actual process execution whether or not a published process exists.','MUST',false),
('REQ-PI-004','Trace Requirements to Primary Problem','Must Requirements must contribute to solving the Primary Problem Statement.','MUST',false),
('REQ-PI-005','Design Process Before Tool','The Future State Process and Information Model must exist before Tool Strategy selection.','MUST',false),
('REQ-PI-006','Preserve End-to-End Traceability','The DOM must relate Problem Statements, Requirements, Acceptance Criteria, Activities, and Configuration Components.','MUST',false),
('REQ-PI-007','Validate With Real Work','Real users must validate Must Requirements using realistic scenarios before go-live.','MUST',false),
('REQ-PI-008','Transfer Process Ownership','Documentation, training, capability verification, and ownership acceptance must occur before handoff completes.','MUST',false),
('REQ-PI-009','Generate Final SOW','The service should generate the Final SOW from approved DOM objects.','SHOULD',false),
('REQ-PI-010','Support Future Workflow Generation','The DOM should store sufficient metadata to support future Camunda workflow generation.','SHOULD',false)
ON CONFLICT(requirement_code) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,requirement_type_code=EXCLUDED.requirement_type_code,updated_at=now();

INSERT INTO problem_requirement(problem_statement_id,requirement_id)
SELECT ps.id,r.id FROM problem_statement ps CROSS JOIN requirement r
WHERE ps.problem_code='PROB-PI-001' AND r.requirement_code BETWEEN 'REQ-PI-001' AND 'REQ-PI-008'
ON CONFLICT(problem_statement_id,requirement_id) DO NOTHING;
INSERT INTO problem_requirement(problem_statement_id,requirement_id)
SELECT ps.id,r.id FROM problem_statement ps CROSS JOIN requirement r
WHERE ps.problem_code='PROB-PI-002' AND r.requirement_code IN ('REQ-PI-006','REQ-PI-009','REQ-PI-010')
ON CONFLICT(problem_statement_id,requirement_id) DO NOTHING;

INSERT INTO acceptance_criterion(acceptance_criterion_code,requirement_id,name,description,criterion_type_code)
SELECT x.code,r.id,x.name,x.description,x.kind
FROM (VALUES
('AC-PI-001','REQ-PI-001','Screening Precedes Approval','A Request cannot enter Awaiting Approval until required screening tests pass.','VALIDATION'),
('AC-PI-002','REQ-PI-002','Required Approvals Complete','Accepted cannot be recorded unless all required approvers returned Approve.','VALIDATION'),
('AC-PI-003','REQ-PI-003','Actual Current State Documented','The Current State Process represents actual execution and separately identifies the Published Process when one exists.','OBSERVATION'),
('AC-PI-004','REQ-PI-004','Must Traceability Complete','Every Must Requirement links to the Primary Problem Statement.','VALIDATION'),
('AC-PI-005','REQ-PI-005','Tool Decision Sequenced','Tool Strategy cannot be finalized before Future State Process and Information Model exist.','VALIDATION'),
('AC-PI-006','REQ-PI-006','Impact Traceability Available','An impact query identifies Requirements and Activities supported by a Configuration Component.','REPORT'),
('AC-PI-007','REQ-PI-007','Must Requirements Pass','Every Must Requirement passes validation or has a governed exception before go-live.','VALIDATION'),
('AC-PI-008','REQ-PI-008','Handoff Conditions Complete','Required training, published documentation, active Process, and ownership acceptance are recorded.','OBSERVATION'),
('AC-PI-009','REQ-PI-009','SOW Generated From DOM','The released SOW identifies the approved DOM source objects used to generate it.','SYSTEM'),
('AC-PI-010','REQ-PI-010','Workflow Metadata Available','Process Steps and Activities contain sequence, type, entry criteria, exit criteria, and Camunda element references where assigned.','REPORT')
) AS x(code,req_code,name,description,kind)
JOIN requirement r ON r.requirement_code=x.req_code
ON CONFLICT(acceptance_criterion_code) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,criterion_type_code=EXCLUDED.criterion_type_code,updated_at=now();

-- ---------------------------------------------------------------------------
-- 9. Record migration
-- ---------------------------------------------------------------------------
INSERT INTO schema_migration (filename, notes)
VALUES ('031_dom_mvp_process_implementation.sql',
        'DOM MVP schema (24 tables); process gains global/local owner and manager role columns alongside the existing owner_role_id (kept, not replaced); metric.owner_role_id dropped as redundant with its process; PMO Process Implementation Service seeded with 8 steps, 51 activities, 2 problem statements, 10 requirements, 10 acceptance criteria.');

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification queries (run after migration)
-- ---------------------------------------------------------------------------
-- SELECT p.process_code,p.name,COUNT(DISTINCT ps.id) AS steps,COUNT(DISTINCT a.id) AS activities
-- FROM process p LEFT JOIN process_step ps ON ps.process_id=p.id
-- LEFT JOIN process_step_activity psa ON psa.process_step_id=ps.id
-- LEFT JOIN activity a ON a.id=psa.activity_id
-- WHERE p.process_code='PROC-003' GROUP BY p.process_code,p.name;
-- Expected: 8 steps and 51 activities.
--
-- SELECT ps.sequence,ps.name,psa.sequence,a.activity_code,a.name,a.activity_type_code
-- FROM process_step ps JOIN process_step_activity psa ON psa.process_step_id=ps.id
-- JOIN activity a ON a.id=psa.activity_id WHERE ps.process_id=(SELECT id FROM process WHERE process_code='PROC-003')
-- ORDER BY ps.sequence,psa.sequence;
