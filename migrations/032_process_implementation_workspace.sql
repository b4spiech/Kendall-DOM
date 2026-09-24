-- 032_process_implementation_workspace.sql
--
-- Adds the Process Implementation Workspace feature end to end: the
-- runtime execution schema, PROC-003's decisions/rules/routing graph, and
-- one worked Data Entity example. Combined into a single migration (rather
-- than the three focused files it was developed as — see the app repo's
-- git history for the individual pieces) because it is one deliverable,
-- applied together, reviewed together.
--
-- Everything created here is either:
--   (a) a new runtime table (workflow_instance, process_step_instance,
--       activity_instance, activity_checklist_item, workflow_data_value,
--       decision_instance, workflow_transition, workflow_audit_event) —
--       records of what happened during one execution of a DOM process,
--       never a reusable definition, or
--   (b) new rows in existing, previously-empty DOM definition tables
--       (decision, choice_set, choice_value, business_rule,
--       activity_decision, data_entity, data_attribute,
--       activity_data_entity) scoped to what PROC-003 actually needs.
-- No existing table's shape changes and no existing row is altered beyond
-- the additive GRANTs below. Idempotency: this migration is written to run
-- once, like every other file in this ledger — re-running it will fail on
-- the CREATE TABLE statements rather than silently double-applying.


BEGIN;

-- =============================================================================
-- PART 1 — Runtime execution schema for the Process Implementation Workspace
-- =============================================================================
--
-- Everything here is a RECORD OF WHAT HAPPENED during one workflow_instance —
-- never a reusable DOM definition. Definitions (process, process_step,
-- activity, decision, business_rule, choice_set, choice_value, data_entity,
-- data_attribute, requirement, acceptance_criterion) are untouched by this
-- migration; runtime rows only ever reference them by id.
--
-- dom_app currently has SELECT everywhere and INSERT on seven tables, no
-- UPDATE/DELETE anywhere (024_app_role_grants.sql). This feature needs to
-- create AND update runtime state (a project's status changes over time,
-- unlike the insert-only document flow), so this migration grants dom_app
-- SELECT/INSERT/UPDATE — never DELETE — on the eight new tables, and adds
-- the same on the columns of `request` and `project` the workflow actually
-- mutates. No existing table's shape changes.
-- ---------------------------------------------------------------------------
-- workflow_instance: one execution of a process (PROC-003, initially).
-- ---------------------------------------------------------------------------
CREATE TABLE workflow_instance (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_id              bigint NOT NULL REFERENCES process(id),
    project_id              bigint REFERENCES project(id),
    request_id              bigint REFERENCES request(id),
    status_code             text NOT NULL DEFAULT 'IN_PROGRESS',
    current_process_step_id bigint REFERENCES process_step(id),
    current_activity_id     bigint REFERENCES activity(id),
    started_by              text NOT NULL,
    started_at              timestamptz NOT NULL DEFAULT now(),
    completed_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (status_code IN ('IN_PROGRESS','ACCEPTED','DEFERRED','REDIRECTED',
                            'DECLINED','COMPLETE','ABANDONED')),
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);
COMMENT ON TABLE workflow_instance IS
    'One execution of a DOM process (e.g. one PROC-003 implementation). '
    'project_id/request_id are null until Step 1 resolves them — an '
    'implementation can be in progress before an Accepted Request exists.';

CREATE INDEX idx_workflow_instance_process ON workflow_instance(process_id);
CREATE INDEX idx_workflow_instance_project ON workflow_instance(project_id);
CREATE INDEX idx_workflow_instance_status  ON workflow_instance(status_code);

-- ---------------------------------------------------------------------------
-- process_step_instance: one step's execution within one workflow_instance.
-- ---------------------------------------------------------------------------
CREATE TABLE process_step_instance (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_instance_id bigint NOT NULL REFERENCES workflow_instance(id),
    process_step_id      bigint NOT NULL REFERENCES process_step(id),
    status_code          text NOT NULL DEFAULT 'NOT_STARTED',
    started_at           timestamptz,
    completed_at         timestamptz,
    completed_by         text,
    invalidated_at       timestamptz,
    invalidated_reason   text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workflow_instance_id, process_step_id),
    CHECK (status_code IN ('NOT_STARTED','IN_PROGRESS','COMPLETE','BLOCKED',
                            'NEEDS_REVIEW','INVALIDATED')),
    CHECK (completed_at IS NULL OR started_at IS NOT NULL)
);
CREATE INDEX idx_step_instance_workflow ON process_step_instance(workflow_instance_id);
CREATE INDEX idx_step_instance_step     ON process_step_instance(process_step_id);

-- ---------------------------------------------------------------------------
-- activity_instance: one activity's execution within one step instance.
-- ---------------------------------------------------------------------------
CREATE TABLE activity_instance (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_step_instance_id bigint NOT NULL REFERENCES process_step_instance(id),
    activity_id              bigint NOT NULL REFERENCES activity(id),
    status_code              text NOT NULL DEFAULT 'NOT_STARTED',
    started_at               timestamptz,
    completed_at             timestamptz,
    completed_by             text,
    completion_notes         text,
    invalidated_at           timestamptz,
    invalidated_reason       text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    UNIQUE (process_step_instance_id, activity_id),
    CHECK (status_code IN ('NOT_STARTED','IN_PROGRESS','COMPLETE','BLOCKED',
                            'SKIPPED','NEEDS_REVIEW','INVALIDATED')),
    CHECK (completed_at IS NULL OR started_at IS NOT NULL)
);
CREATE INDEX idx_activity_instance_step ON activity_instance(process_step_instance_id);
CREATE INDEX idx_activity_instance_activity ON activity_instance(activity_id);
CREATE INDEX idx_activity_instance_status ON activity_instance(status_code);

-- ---------------------------------------------------------------------------
-- activity_checklist_item: one checklist line, snapshotted from
-- activity.activity_instructions at the moment the activity instance starts
-- — so a later edit to the DOM definition never rewrites history for a
-- project already under way.
-- ---------------------------------------------------------------------------
CREATE TABLE activity_checklist_item (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_instance_id bigint NOT NULL REFERENCES activity_instance(id),
    item_key             text NOT NULL,
    item_text_snapshot   text NOT NULL,
    display_order        int NOT NULL DEFAULT 0,
    is_required          boolean NOT NULL DEFAULT true,
    is_complete          boolean NOT NULL DEFAULT false,
    completed_by         text,
    completed_at         timestamptz,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (activity_instance_id, item_key),
    CHECK ((is_complete AND completed_at IS NOT NULL) OR
           (NOT is_complete AND completed_by IS NULL AND completed_at IS NULL))
);
CREATE INDEX idx_checklist_item_activity_instance ON activity_checklist_item(activity_instance_id);

-- ---------------------------------------------------------------------------
-- workflow_data_value: one captured field value. data_entity_id/
-- data_attribute_id are nullable so an activity with no formal DOM
-- attribute mapping can still capture a free-text note (see
-- ARCHITECTURE_WORKFLOW.md — most activities have no mapping yet since
-- data_entity/data_attribute are empty in the current DOM).
-- ---------------------------------------------------------------------------
CREATE TABLE workflow_data_value (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_instance_id  bigint NOT NULL REFERENCES workflow_instance(id),
    activity_instance_id  bigint REFERENCES activity_instance(id),
    data_entity_id        bigint REFERENCES data_entity(id),
    data_attribute_id     bigint REFERENCES data_attribute(id),
    field_key             text NOT NULL,
    value_text            text,
    value_numeric         numeric,
    value_boolean         boolean,
    value_date            date,
    value_datetime        timestamptz,
    choice_value_id       bigint REFERENCES choice_value(id),
    reference_object_type text,
    reference_object_id   bigint,
    source_type_code      text NOT NULL DEFAULT 'CAPTURED',
    created_by            text NOT NULL,
    updated_by            text NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workflow_instance_id, activity_instance_id, field_key),
    CHECK (source_type_code IN ('CAPTURED','INHERITED','CALCULATED','SYSTEM'))
);
COMMENT ON COLUMN workflow_data_value.field_key IS
    'Stable key for this field on its activity — data_attribute.attribute_code '
    'when a DOM mapping exists, else an application-defined key (e.g. '
    '"notes"). Lets a value be found without a DOM attribute row existing.';
COMMENT ON COLUMN workflow_data_value.source_type_code IS
    'CAPTURED: entered on this activity. INHERITED: copied read-only from an '
    'earlier answer (Request/Project field, or an earlier workflow_data_value) '
    '— reference_object_type/id names the source. CALCULATED: derived. '
    'SYSTEM: set by workflow logic, not a person.';

CREATE INDEX idx_data_value_workflow ON workflow_data_value(workflow_instance_id);
CREATE INDEX idx_data_value_activity_instance ON workflow_data_value(activity_instance_id);
CREATE INDEX idx_data_value_attribute ON workflow_data_value(data_attribute_id);

-- ---------------------------------------------------------------------------
-- decision_instance: one recorded decision outcome. Superseding an earlier
-- decision inserts a new row and flips is_current — the old row is never
-- edited or deleted, so the audit trail is the table itself.
-- ---------------------------------------------------------------------------
CREATE TABLE decision_instance (
    id                              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_instance_id            bigint NOT NULL REFERENCES workflow_instance(id),
    activity_instance_id            bigint NOT NULL REFERENCES activity_instance(id),
    decision_id                     bigint NOT NULL REFERENCES decision(id),
    selected_choice_value_id        bigint REFERENCES choice_value(id),
    value_boolean                   boolean,
    value_numeric                   numeric,
    value_text                      text,
    explanation                     text,
    decided_by                      text NOT NULL,
    decided_at                      timestamptz NOT NULL DEFAULT now(),
    supersedes_decision_instance_id bigint REFERENCES decision_instance(id),
    is_current                      boolean NOT NULL DEFAULT true,
    created_at                      timestamptz NOT NULL DEFAULT now(),
    updated_at                      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_decision_instance_workflow ON decision_instance(workflow_instance_id);
CREATE INDEX idx_decision_instance_activity ON decision_instance(activity_instance_id);
CREATE INDEX idx_decision_instance_decision ON decision_instance(decision_id);
-- At most one current decision per (workflow, decision) — superseding must
-- flip the old row's is_current to false in the same transaction.
CREATE UNIQUE INDEX uq_decision_instance_current
    ON decision_instance(workflow_instance_id, decision_id) WHERE is_current;

-- ---------------------------------------------------------------------------
-- workflow_transition: routing data. Read by the routing service instead of
-- a hardcoded switch statement — see workflow/routing.py.
-- ---------------------------------------------------------------------------
CREATE TABLE workflow_transition (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_id           bigint NOT NULL REFERENCES process(id),
    from_activity_id     bigint NOT NULL REFERENCES activity(id),
    decision_id          bigint REFERENCES decision(id),
    choice_value_id      bigint REFERENCES choice_value(id),
    to_activity_id       bigint REFERENCES activity(id),
    to_process_step_id   bigint REFERENCES process_step(id),
    transition_type_code text NOT NULL,
    condition_expression text,
    priority             int NOT NULL DEFAULT 100,
    is_default           boolean NOT NULL DEFAULT false,
    is_active            boolean NOT NULL DEFAULT true,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (transition_type_code IN ('SEQUENTIAL','DECISION_BRANCH','LOOP_BACK','TERMINAL')),
    CHECK (to_activity_id IS NOT NULL OR to_process_step_id IS NOT NULL
           OR transition_type_code = 'TERMINAL'),
    -- A decision-branch transition names the choice it fires on; a default
    -- (sequential/terminal) transition carries no decision — never both.
    CHECK ((decision_id IS NULL) = (choice_value_id IS NULL))
);
COMMENT ON TABLE workflow_transition IS
    'PROC-003''s routing graph as data. condition_expression is reserved for '
    'a future rule too complex for a plain decision/choice_value match — no '
    'seeded row uses it yet, and the routing service does not evaluate it.';

CREATE INDEX idx_transition_from_activity ON workflow_transition(from_activity_id);
CREATE INDEX idx_transition_process ON workflow_transition(process_id);
CREATE INDEX idx_transition_decision ON workflow_transition(decision_id, choice_value_id);

-- ---------------------------------------------------------------------------
-- workflow_audit_event: append-only history. Nothing in this feature updates
-- or deletes a row here — see workflow/audit.py.
-- ---------------------------------------------------------------------------
CREATE TABLE workflow_audit_event (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_instance_id bigint NOT NULL REFERENCES workflow_instance(id),
    activity_instance_id bigint REFERENCES activity_instance(id),
    entity_type          text NOT NULL,
    entity_id            bigint NOT NULL,
    action               text NOT NULL,
    old_value            jsonb,
    new_value            jsonb,
    changed_by           text NOT NULL,
    changed_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_workflow ON workflow_audit_event(workflow_instance_id, changed_at DESC);
CREATE INDEX idx_audit_activity_instance ON workflow_audit_event(activity_instance_id);
CREATE INDEX idx_audit_entity ON workflow_audit_event(entity_type, entity_id);

-- ---------------------------------------------------------------------------
-- Grants. Additive only — no existing grant is revoked.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON
    workflow_instance, process_step_instance, activity_instance,
    activity_checklist_item, workflow_data_value, decision_instance,
    workflow_transition, workflow_audit_event
    TO dom_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dom_app;

-- request/project are existing DOM tables dom_app could previously only
-- SELECT. The workflow creates a Request at Step 1 and updates its
-- disposition; it creates a Project on Accepted and updates its status.
-- Column-limited to what the workflow actually writes, same discipline as
-- 014_service_role_grants.sql's dom_writer.
GRANT INSERT ON request TO dom_app;
GRANT UPDATE (status_code, decision_code, decision_reason, revisit_date,
              redirect_destination, project_id, reviewed_by, reviewed_at,
              updated_at) ON request TO dom_app;
GRANT INSERT ON project TO dom_app;
GRANT UPDATE (status_code, actual_end_date, updated_at) ON project TO dom_app;

-- problem_statement is a DOM definition table, but PROC-003's own Step 3
-- ("Refine Problem Statement", ACT-PI-018) is what actually produces a new
-- Project's Primary Problem Statement — there is no other mechanism in the
-- current DOM that creates one. Without this grant, Step 3's "exactly one
-- Primary Problem Statement" rule (validation.py) could never be satisfied
-- for any Project other than the one pre-existing bootstrap Project.
GRANT INSERT ON problem_statement TO dom_app;

-- Likewise problem_requirement: selecting a Requirement for a Project at
-- ACT-PI-019 links it to the Project's Primary Problem Statement (see
-- workflow/service.py's set_requirement_selection) — the traceability rule
-- validation.py enforces in Step 3 could otherwise never be satisfied for
-- any Project other than the bootstrap one, since a reusable Requirement's
-- existing problem_requirement rows point at whichever Project first used
-- it, not at every Project that reuses it afterward.
GRANT INSERT ON problem_requirement TO dom_app;

-- =============================================================================
-- PART 2 — PROC-003 DOM seed data (decisions, choice sets/values, rules) and
-- the workflow_transition routing graph for all 51 activities
-- =============================================================================
--
-- decision, choice_set, choice_value, business_rule, and activity_decision
-- were created empty by 031_dom_mvp_process_implementation.sql — this
-- migration is the first to populate them, scoped to what PROC-003's Step 1
-- branching (and the four loop-backs elsewhere) actually needs. These are
-- DOM definition rows, not application code: the routing service and the
-- guided UI read them, nothing hardcodes them.
--
-- DEC-PI-007 (Request Disposition) is recorded by the application, not
-- chosen by the user — see workflow/routing.py's PROC003_DISPOSITION_RULE.
-- It still needs a real DOM decision row because decision_instance.decision_id
-- is a foreign key.
-- ---------------------------------------------------------------------------
-- Choice sets and values
-- ---------------------------------------------------------------------------
INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-001', 'Information Complete', 'Whether enough information exists to screen the Request.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-001a', id, 'Complete', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-001';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-001b', id, 'Pending Information', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-001';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-002', 'Process Solvable', 'Whether the Request can be addressed by a repeatable, PMO-implementable process.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-002a', id, 'Solvable', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-002';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-002b', id, 'Not Solvable', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-002';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-003', 'PMO Scope', 'Whether the Request belongs to the PMO Process Implementation Service or another service.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-003a', id, 'In Scope', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-003';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-003b', id, 'Redirect to CI/OPEX', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-003';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-003c', id, 'Redirect to IS', 3 FROM choice_set WHERE choice_set_code = 'CS-PI-003';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-004', 'Capacity Available', 'Whether PMO has capacity to take on the implementation now.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-004a', id, 'Available', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-004';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-004b', id, 'Unavailable', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-004';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-005', 'Existing Solution Found', 'Whether an existing solution already satisfies the Request.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-005a', id, 'No', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-005';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-005b', id, 'Yes', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-005';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-006', 'Required Approvals Result', 'Whether every required approver (BU Owner, Process Owner) approved.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-006a', id, 'All Approved', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-006';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-006b', id, 'One or More Declined', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-006';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-007', 'Request Disposition', 'The official Request outcome, computed from the screening and approval decisions above — not separately chosen.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-007a', id, 'Accepted', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-007';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-007b', id, 'Deferred', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-007';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-007c', id, 'Redirected', 3 FROM choice_set WHERE choice_set_code = 'CS-PI-007';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-007d', id, 'Declined', 4 FROM choice_set WHERE choice_set_code = 'CS-PI-007';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-008', 'Configuration Gap Found', 'Whether the configured solution has a gap against the approved design.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-008a', id, 'No', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-008';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-008b', id, 'Yes', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-008';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-009', 'Validation Finding Classification', 'Whether a validation scenario result is a pass or a defect.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-009a', id, 'Pass', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-009';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-009b', id, 'Defect', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-009';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-010', 'Go-Live Recommendation', 'Whether validation supports going live.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-010a', id, 'Ready', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-010';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-010b', id, 'Not Ready', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-010';

INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable) VALUES
    ('CS-PI-011', 'Critical Issue Found', 'Whether a critical issue was found during stabilization monitoring.', false);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-011a', id, 'No', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-011';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order) SELECT 'CV-PI-011b', id, 'Yes', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-011';

-- ---------------------------------------------------------------------------
-- Business rules
-- ---------------------------------------------------------------------------
INSERT INTO business_rule (rule_code, name, rule_type_code, definition, example_pass, example_fail, is_reusable) VALUES
    ('RULE-PI-001', 'Solvable Only If PMO-Implementable', 'GOVERNANCE', 'A Request is Solvable only if it can be addressed by a repeatable process PMO can implement without custom software development.', 'A recurring approval bottleneck with a clear owner and steps.', 'A one-time request to build a new internal tool from scratch.', false);
INSERT INTO business_rule (rule_code, name, rule_type_code, definition, example_pass, example_fail, is_reusable) VALUES
    ('RULE-PI-002', 'Operational-Only Redirects to CI/OPEX', 'GOVERNANCE', 'A Request whose need is a single team''s operational execution, with no cross-functional process to implement, redirects to CI/OPEX rather than PMO.', 'Cross-department bid tracking with multiple approver roles.', 'One team''s internal daily checklist with no other stakeholders.', false);
INSERT INTO business_rule (rule_code, name, rule_type_code, definition, example_pass, example_fail, is_reusable) VALUES
    ('RULE-PI-003', 'Capacity Checked Against Active Portfolio', 'GOVERNANCE', 'Capacity is Available only if PMO''s active Project count is below its stated concurrent-implementation limit.', 'PMO has 2 active Projects against a limit of 4.', 'PMO has 4 active Projects against a limit of 4.', false);
INSERT INTO business_rule (rule_code, name, rule_type_code, definition, example_pass, example_fail, is_reusable) VALUES
    ('RULE-PI-004', 'Both Approvers Must Approve', 'APPROVAL', 'All Required Approvals = Approve only if both the BU Owner and the Process Owner approve; a single Decline fails the Request regardless of the other response.', 'BU Owner approves and Process Owner approves.', 'BU Owner approves and Process Owner declines.', false);

-- ---------------------------------------------------------------------------
-- Decisions, linked to their choice set, their activity, and their rules
-- ---------------------------------------------------------------------------
INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-001', 'Information Complete', 'Whether enough information exists to screen the Request.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-001';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-003' AND d.decision_code = 'DEC-PI-001';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-002', 'Process Solvable', 'Whether the Request can be addressed by a repeatable, PMO-implementable process.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-002';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-004' AND d.decision_code = 'DEC-PI-002';
INSERT INTO decision_rule (decision_id, rule_id, sequence)
    SELECT d.id, r.id, 1 FROM decision d, business_rule r
    WHERE d.decision_code = 'DEC-PI-002' AND r.rule_code = 'RULE-PI-001';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-003', 'PMO Scope', 'Whether the Request belongs to the PMO Process Implementation Service or another service.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-003';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-004' AND d.decision_code = 'DEC-PI-003';
INSERT INTO decision_rule (decision_id, rule_id, sequence)
    SELECT d.id, r.id, 1 FROM decision d, business_rule r
    WHERE d.decision_code = 'DEC-PI-003' AND r.rule_code = 'RULE-PI-002';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-004', 'Capacity Available', 'Whether PMO has capacity to take on the implementation now.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-004';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-004' AND d.decision_code = 'DEC-PI-004';
INSERT INTO decision_rule (decision_id, rule_id, sequence)
    SELECT d.id, r.id, 1 FROM decision d, business_rule r
    WHERE d.decision_code = 'DEC-PI-004' AND r.rule_code = 'RULE-PI-003';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-005', 'Existing Solution Found', 'Whether an existing solution already satisfies the Request.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-005';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-004' AND d.decision_code = 'DEC-PI-005';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-006', 'Required Approvals Result', 'Whether every required approver (BU Owner, Process Owner) approved.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-006';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-006' AND d.decision_code = 'DEC-PI-006';
INSERT INTO decision_rule (decision_id, rule_id, sequence)
    SELECT d.id, r.id, 1 FROM decision d, business_rule r
    WHERE d.decision_code = 'DEC-PI-006' AND r.rule_code = 'RULE-PI-004';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-007', 'Request Disposition', 'The official Request outcome, computed from the screening and approval decisions above — not separately chosen.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-007';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-007' AND d.decision_code = 'DEC-PI-007';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-008', 'Configuration Gap Found', 'Whether the configured solution has a gap against the approved design.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-008';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-032' AND d.decision_code = 'DEC-PI-008';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-009', 'Validation Finding Classification', 'Whether a validation scenario result is a pass or a defect.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-009';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-037' AND d.decision_code = 'DEC-PI-009';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-010', 'Go-Live Recommendation', 'Whether validation supports going live.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-010';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-040' AND d.decision_code = 'DEC-PI-010';

INSERT INTO decision (decision_code, name, purpose, outcome_type_code, choice_set_id, is_reusable)
    SELECT 'DEC-PI-011', 'Critical Issue Found', 'Whether a critical issue was found during stabilization monitoring.', 'CHOICE', cs.id, false
    FROM choice_set cs WHERE cs.choice_set_code = 'CS-PI-011';
INSERT INTO activity_decision (activity_id, decision_id, sequence)
    SELECT a.id, d.id, 1 FROM activity a, decision d
    WHERE a.activity_code = 'ACT-PI-047' AND d.decision_code = 'DEC-PI-011';

-- ---------------------------------------------------------------------------
-- workflow_transition: the routing graph for all 51 activities
-- ---------------------------------------------------------------------------
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-001'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-002'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-002'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-003'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-003'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-001'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-001b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-003'), NULL, 'LOOP_BACK', 10, false, 'Missing information -> Pending Information, return to Verify Required Information.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-003'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-002'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-002b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'DECISION_BRANCH', 10, false, 'Not process-solvable -> skip to Issue Decision.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-003'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-003b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'DECISION_BRANCH', 20, false, 'Operational scope -> Redirect to CI/OPEX.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-003'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-003c'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'DECISION_BRANCH', 21, false, 'Custom technology request -> Redirect to IS.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-004'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-004b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'DECISION_BRANCH', 30, false, 'No capacity -> Deferred.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-005'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-005b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'DECISION_BRANCH', 40, false, 'Existing solution found -> Declined.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-004'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-005'), NULL, 'SEQUENTIAL', 100, true, 'Screening passed -> continue to Validate Owners.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-005'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-006'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-006'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, 'SEQUENTIAL', 100, true, 'Both approval outcomes funnel to Issue Decision, which records the disposition.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-007'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-007a'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-008'), NULL, 'DECISION_BRANCH', 10, false, 'Accepted -> Create Project.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-007'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-009'), NULL, 'SEQUENTIAL', 100, true, 'Deferred/Redirected/Declined -> skip Create Project, go to Notify Requester.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-008'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-009'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-009'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-010'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-010'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-007'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-007a'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-011'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-011' AND ps.sequence = 2), 'SEQUENTIAL', 10, false, 'Accepted -> Step 2 begins.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-010'), NULL, NULL, NULL, NULL, 'TERMINAL', 100, true, 'Deferred/Redirected/Declined -> workflow stops active progression; Request retains its disposition.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-011'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-012'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-012'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-013'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-013'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-014'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-014'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-015'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-015'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-016'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-016'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-017'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-017'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-018'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-018' AND ps.sequence = 3), 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-018'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-019'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-019'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-020'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-020'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-021'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-021'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-022'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-022'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-023'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-023' AND ps.sequence = 4), 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-023'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-024'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-024'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-025'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-025'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-026'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-026'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-027'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-027'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-028'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-028'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-029'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-029'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-030'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-030' AND ps.sequence = 5), 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-030'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-031'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-031'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-032'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-032'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-008'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-008b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-033'), NULL, 'DECISION_BRANCH', 10, false, 'Configuration gap found -> Correct Configuration Gap.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-032'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-034'), NULL, 'SEQUENTIAL', 100, true, 'No gap -> Prepare Validation Environment.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-033'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-032'), NULL, 'LOOP_BACK', 100, true, 'Re-review configuration after correction.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-034'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-035'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-035' AND ps.sequence = 6), 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-035'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-036'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-036'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-037'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-037'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-009'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-009b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-038'), NULL, 'DECISION_BRANCH', 10, false, 'Defect -> Correct Validation Defect.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-037'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-039'), NULL, 'SEQUENTIAL', 100, true, 'Pass -> Review Validation Results.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-038'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-035'), NULL, 'LOOP_BACK', 100, true, 'Retest after correcting the defect.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-039'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-040'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-040'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-010'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-010b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-039'), NULL, 'LOOP_BACK', 10, false, 'Not Ready -> return to unresolved validation findings; Step 7 is blocked.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-040'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-010'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-010a'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-041'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-041' AND ps.sequence = 7), 'SEQUENTIAL', 100, false, 'Ready -> Step 7 begins.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-041'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-042'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-042'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-043'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-043'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-044'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-044'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-045'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-045'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-046'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-046'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-047'), (SELECT ps.id FROM activity a JOIN process_step_activity psa ON psa.activity_id=a.id JOIN process_step ps ON ps.id=psa.process_step_id WHERE a.activity_code = 'ACT-PI-047' AND ps.sequence = 8), 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-047'), (SELECT id FROM decision WHERE decision_code = 'DEC-PI-011'), (SELECT id FROM choice_value WHERE choice_value_code = 'CV-PI-011b'), (SELECT id FROM activity WHERE activity_code = 'ACT-PI-048'), NULL, 'DECISION_BRANCH', 10, false, 'Critical issue -> Resolve Critical Issue.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-047'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-049'), NULL, 'SEQUENTIAL', 100, true, 'No critical issue -> Capture Lessons Learned.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-048'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-047'), NULL, 'LOOP_BACK', 100, true, 'Resume monitoring after resolving the issue.'
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-049'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-050'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-050'), NULL, NULL, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-051'), NULL, 'SEQUENTIAL', 100, true, NULL
    FROM process p WHERE p.process_code = 'PROC-003';
INSERT INTO workflow_transition (process_id, from_activity_id, decision_id, choice_value_id, to_activity_id, to_process_step_id, transition_type_code, priority, is_default, notes)
    SELECT p.id, (SELECT id FROM activity WHERE activity_code = 'ACT-PI-051'), NULL, NULL, NULL, NULL, 'TERMINAL', 100, true, 'Project closes; the Process itself remains active for future implementations.'
    FROM process p WHERE p.process_code = 'PROC-003';

-- =============================================================================
-- PART 3 — One Data Entity / Data Attribute example wired into PROC-003
-- =============================================================================
--
-- So the dynamic data-entry renderer (workflow/documents rendering
-- DOM-mapped controls) has real DOM data to render against rather than
-- only the generic free-text fallback every activity gets.
--
-- Scope is deliberately small: data_entity/data_attribute/
-- activity_data_entity are empty in the current DOM (see DATABASE.md), and
-- populating all 51 activities with formal attribute mappings is well
-- beyond what proves the mechanism works. One entity, mapped to the two
-- Step 2 activities it naturally belongs to (documented in
-- ARCHITECTURE_WORKFLOW.md as an MVP scope decision), is enough to
-- demonstrate a real choice_set-backed dropdown loading from the DOM.
INSERT INTO choice_set (choice_set_code, name, purpose, is_reusable)
    VALUES ('CS-PI-012', 'Impact Level', 'Severity of a current-state finding.', true);
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order)
    SELECT 'CV-PI-012a', id, 'Low', 1 FROM choice_set WHERE choice_set_code = 'CS-PI-012';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order)
    SELECT 'CV-PI-012b', id, 'Medium', 2 FROM choice_set WHERE choice_set_code = 'CS-PI-012';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order)
    SELECT 'CV-PI-012c', id, 'High', 3 FROM choice_set WHERE choice_set_code = 'CS-PI-012';
INSERT INTO choice_value (choice_value_code, choice_set_id, name, display_order)
    SELECT 'CV-PI-012d', id, 'Critical', 4 FROM choice_set WHERE choice_set_code = 'CS-PI-012';

INSERT INTO data_entity (entity_code, name, purpose, data_owner_role_id, is_reusable)
    SELECT 'DE-PI-001', 'Current State Finding',
           'A documented observation about how a process currently operates, captured during discovery.',
           r.id, true
    FROM role r WHERE r.role_code = 'R-003';

INSERT INTO data_attribute (attribute_code, data_entity_id, name, attribute_type_code, is_required)
    SELECT 'ATTR-PI-001', de.id, 'Pain Point Description', 'TEXT', true
    FROM data_entity de WHERE de.entity_code = 'DE-PI-001';

INSERT INTO data_attribute (attribute_code, data_entity_id, name, attribute_type_code, choice_set_id, is_required)
    SELECT 'ATTR-PI-002', de.id, 'Impact Level', 'CHOICE', cs.id, true
    FROM data_entity de, choice_set cs
    WHERE de.entity_code = 'DE-PI-001' AND cs.choice_set_code = 'CS-PI-012';

INSERT INTO data_attribute (attribute_code, data_entity_id, name, attribute_type_code, is_required)
    SELECT 'ATTR-PI-003', de.id, 'Root Cause', 'TEXT', false
    FROM data_entity de WHERE de.entity_code = 'DE-PI-001';

INSERT INTO activity_data_entity (activity_id, data_entity_id, usage_type_code)
    SELECT a.id, de.id, 'CREATES'
    FROM activity a, data_entity de
    WHERE a.activity_code = 'ACT-PI-016' AND de.entity_code = 'DE-PI-001';

INSERT INTO activity_data_entity (activity_id, data_entity_id, usage_type_code)
    SELECT a.id, de.id, 'CONSUMES'
    FROM activity a, data_entity de
    WHERE a.activity_code = 'ACT-PI-017' AND de.entity_code = 'DE-PI-001';

INSERT INTO schema_migration (filename, notes) VALUES
    ('032_process_implementation_workspace.sql',
     'Process Implementation Workspace: runtime execution schema (8 tables: '
     'workflow_instance, process_step_instance, activity_instance, '
     'activity_checklist_item, workflow_data_value, decision_instance, '
     'workflow_transition, workflow_audit_event) with dom_app SELECT/INSERT/'
     'UPDATE (no DELETE) on all eight, plus INSERT and column-limited UPDATE '
     'on request/project, plus INSERT on problem_statement/problem_requirement '
     '(Step 3 creates and links the Project''s Primary Problem Statement). '
     'PROC-003 DOM seed data: 11 decisions, ~27 choice values, 4 business '
     'rules, 63 workflow_transition rows covering all 51 activities. One '
     'Data Entity example (Current State Finding) mapped to ACT-PI-016/017.');

COMMIT;
