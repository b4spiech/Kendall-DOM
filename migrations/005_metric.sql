-- 005_metric.sql
-- Creates the metric entity and links metrics to the processes they measure.
-- Depends on: 001 (metric_type), 002 (role, system), 003 (process)
--
-- Field set carried over from the Metric Hooks list in Schema v1, with two
-- changes:
--
--   1. Related_Entity_Type / Related_Entity_IDs was a single choice column plus
--      a semicolon-delimited text column ("D-001; GT-001"). That is a SharePoint
--      workaround. Here it becomes a real junction table.
--   2. Instrumentation_Status collapses to is_instrumented. The KPI in the pilot
--      is tracked outside any system today, which is exactly the "identified but
--      not instrumented" case this flag records.

BEGIN;

CREATE TABLE metric (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_code       text NOT NULL UNIQUE,
    name              text NOT NULL,
    metric_type_code  text NOT NULL REFERENCES metric_type(code),

    definition        text,
    calculation       text,
    target_value      text,
    unit              text,

    -- Where the number comes from today. NULL is meaningful: it means nobody has
    -- established a source, which is a finding rather than missing data entry.
    source_system_id  bigint REFERENCES system(id),
    capture_point     text,
    is_instrumented   boolean NOT NULL DEFAULT false,

    owner_role_id     bigint REFERENCES role(id),
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT metric_code_format CHECK (metric_code ~ '^M-[0-9]{3}$')
);

-- ---------------------------------------------------------------------------
-- process_metric
-- The metric measures the process. It reaches the SOP by way of
-- document.governs_process_id, not by a direct document-to-metric FK.
-- ---------------------------------------------------------------------------
CREATE TABLE process_metric (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_id  bigint NOT NULL REFERENCES process(id) ON DELETE CASCADE,
    metric_id   bigint NOT NULL REFERENCES metric(id),
    is_primary  boolean NOT NULL DEFAULT false,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT process_metric_unique UNIQUE (process_id, metric_id)
);

COMMIT;
