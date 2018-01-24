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

CREATE TABLE users (
    user_ui_id      SERIAL          PRIMARY KEY,
    username        VARCHAR(255)    NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL
);

CREATE TABLE feeds (
    feed_ui_id      BIGSERIAL   PRIMARY KEY,
    user_ui_id      INTEGER     NOT NULL REFERENCES users(user_ui_id),
    stamp           TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE TABLE runs (
    run_ui_id       BIGSERIAL   PRIMARY KEY,
    feed_ui_id      BIGINT      NOT NULL REFERENCES feeds(feed_ui_id),

    run_id          TEXT        NOT NULL,

    UNIQUE(feed_ui_id, run_id)
);

CREATE TABLE jobs (
    job_ui_id       BIGSERIAL   PRIMARY KEY,
    run_ui_id       BIGINT      NOT NULL REFERENCES runs(run_ui_id),

    file            TEXT,
    job_id          TEXT        NOT NULL,

    UNIQUE(run_ui_id, job_id)
);

CREATE TABLE events (
    event_ui_id     BIGSERIAL   PRIMARY KEY,
    job_ui_id       BIGSERIAL   NOT NULL REFERENCES jobs(job_ui_id),

    stamp           TIMESTAMP,

    event_id        TEXT        NOT NULL,
    stream_id       TEXT,

    UNIQUE(job_ui_id, event_id)
);

CREATE TABLE facets (
    facet_ui_id     BIGSERIAL   PRIMARY KEY,
    event_ui_id     BIGINT      NOT NULL REFERENCES events(event_ui_id),

    facet_type      facet_type  NOT NULL DEFAULT 'other',

    facet_name      TEXT        NOT NULL,
    facet_value     JSONB       NOT NULL
);

ALTER TABLE runs ADD facet_ui_id BIGINT REFERENCES facets(facet_ui_id) UNIQUE;
ALTER TABLE jobs ADD facet_ui_id BIGINT REFERENCES facets(facet_ui_id) UNIQUE;

CREATE INDEX IF NOT EXISTS run_jobs          ON jobs   (run_ui_id);
CREATE INDEX IF NOT EXISTS job_events        ON events (job_ui_id);
CREATE INDEX IF NOT EXISTS facet_type_index  ON facets (facet_type);
CREATE INDEX IF NOT EXISTS facet_event_index ON facets (event_ui_id);
