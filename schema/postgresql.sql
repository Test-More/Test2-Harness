CREATE TABLE users (
    user_id         SERIAL          PRIMARY KEY,
    username        VARCHAR(255)    NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL
);

CREATE TABLE streams (
    stream_id       BIGSERIAL   PRIMARY KEY,
    user_id         INTEGER     NOT NULL REFERENCES users(user_id)
);

CREATE TABLE runs (
    run_ui_id       BIGSERIAL   PRIMARY KEY,
    stream_id       BIGINT      NOT NULL REFERENCES streams(stream_id),
    run_id          TEXT        NOT NULL,

    UNIQUE(stream_id, run_id)
);

CREATE TABLE jobs (
    job_ui_id       BIGSERIAL   PRIMARY KEY,
    run_ui_id       BIGINT      NOT NULL REFERENCES runs(run_ui_id),

    job_id          TEXT        NOT NULL,

    UNIQUE(job_ui_id, run_ui_id)
);

CREATE TABLE events (
    event_ui_id     BIGSERIAL   PRIMARY KEY,
    job_ui_id       BIGSERIAL   NOT NULL REFERENCES jobs(job_ui_id),

    stamp           DECIMAL,

    event_id        TEXT        NOT NULL,
    stream_id       TEXT,

    UNIQUE(job_ui_id, event_id)
);

CREATE TYPE facet_type AS ENUM(
    'other',
    'about',
    'amnesty',
    'assert',
    'control',
    'error',
    'info',
    'meta',
    'parent',
    'plan',
    'trace',
    'harness',
    'harness_run',
    'harness_job',
    'harness_job_launch',
    'harness_job_start',
    'harness_job_exit',
    'harness_job_end'
);

CREATE TABLE facets (
    facet_ui_id     BIGSERIAL   PRIMARY KEY,
    event_ui_id     BIGINT      NOT NULL REFERENCES events(event_ui_id),

    facet_type      facet_type  NOT NULL DEFAULT 'other',

    facet_name      TEXT        NOT NULL,
    facet_value     JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS run_jobs          ON jobs   (run_ui_id);
CREATE INDEX IF NOT EXISTS job_events        ON events (job_ui_id);
CREATE INDEX IF NOT EXISTS facet_type_index  ON facets (facet_type);
CREATE INDEX IF NOT EXISTS facet_event_index ON facets (event_ui_id);
