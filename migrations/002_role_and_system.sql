-- 002_role_and_system.sql
-- Creates the two foundational entity tables that most other tables reference.
-- Depends on: 001 (nothing structural, but keeps run order explicit)
--
-- Build order follows the Entity Lists sheet: Roles first, then Systems Tools,
-- because artifacts, documents, and metrics all look up to them.

BEGIN;

-- ---------------------------------------------------------------------------
-- role
-- Role/title records used for ownership, accountability, and approval routing.
-- NEVER a named person. "PMO Manager", not "Brad".
--
-- `role` is a non-reserved keyword in Postgres, so this table name is legal.
-- Be aware that \du lists database roles, which are a different thing entirely.
-- ---------------------------------------------------------------------------
CREATE TABLE role (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_code               text NOT NULL UNIQUE,
    name                    text NOT NULL,
    role_type               text,
    purpose                 text,
    responsibility_summary  text,
    approval_authority      text,
    is_active               boolean NOT NULL DEFAULT true,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT role_code_format CHECK (role_code ~ '^R-[0-9]{3}$')
);

-- ---------------------------------------------------------------------------
-- system
-- Tools/platforms where work happens, records live, or documents are stored.
-- ---------------------------------------------------------------------------
CREATE TABLE system (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    system_code         text NOT NULL UNIQUE,
    name                text NOT NULL,
    system_type         text,
    current_state_role  text,
    base_url            text,
    is_current          boolean NOT NULL DEFAULT true,
    owner_role_id       bigint REFERENCES role(id),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT system_code_format CHECK (system_code ~ '^SYS-[0-9]{3}$')
);

COMMIT;
