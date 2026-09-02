-- 012_role_system_identity.sql
-- Maps a DOM role to the group or account that represents it in an external
-- system.
-- Depends on: 002 (role, system)
--
-- THE PROBLEM
--
-- The DOM says "Project Manager must approve." ADO needs to know which account
-- or group that resolves to today. Those are different facts with different
-- lifecycles: the role is stable, its occupants are not.
--
-- WHY NOT MATCH ON NAME
--
-- Naming an ADO group "Project Manager" to match role R-003 looks like a link but
-- is not one. Rename either side and the connection breaks with no error — the
-- same silent-breakage failure as the hardcoded form URL and the individual email
-- address found during the SOP-001 review.
--
-- external_id holds the system's stable identifier (an ADO group descriptor or
-- origin GUID). external_name is a convenience label for humans and is expected
-- to drift; nothing resolves against it.
--
-- WHY A JUNCTION TABLE RATHER THAN COLUMNS ON role
--
-- ado_group_id, planview_group_id, sharepoint_group_id would mean a schema change
-- per system. This table takes a new row instead — the same shape that will map
-- DOM entities to Planview objects later.

BEGIN;

CREATE TABLE role_system_identity (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_id        bigint NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    system_id      bigint NOT NULL REFERENCES system(id),

    -- The system's stable identifier. This is what automation resolves against.
    external_id    text NOT NULL,

    -- Human-readable label. Display only — may go stale after a rename, and that
    -- is acceptable because nothing depends on it.
    external_name  text,

    -- 'group' or 'user'. Groups are strongly preferred: a user mapping puts an
    -- individual back into a governance rule, which is what this table exists to
    -- avoid.
    identity_type  text NOT NULL DEFAULT 'group',

    is_active      boolean NOT NULL DEFAULT true,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT role_system_identity_unique
        UNIQUE (role_id, system_id, external_id),
    CONSTRAINT role_system_identity_type_valid
        CHECK (identity_type IN ('group', 'user'))
);

CREATE INDEX role_system_identity_role_id_idx   ON role_system_identity (role_id);
CREATE INDEX role_system_identity_external_idx  ON role_system_identity (system_id, external_id);

COMMENT ON TABLE role_system_identity IS
    'Resolves a DOM role to its representation in an external system. Roles are stable; their occupants and system identifiers are not.';

INSERT INTO schema_migration (filename, notes)
VALUES ('012_role_system_identity.sql',
        'Maps DOM roles to external system groups by stable identifier, not by name.');

COMMIT;
