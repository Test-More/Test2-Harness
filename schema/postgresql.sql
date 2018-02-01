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

CREATE TYPE perms AS ENUM(
    'private',
    'protected',
    'public'
);

CREATE TYPE api_key_status AS ENUM(
    'active',
    'disabled',
    'revoked'
);

CREATE TABLE users (
    user_ui_id      SERIAL          PRIMARY KEY,
    username        VARCHAR(32)     NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL,
    is_admin        BOOL            DEFAULT FALSE,

    UNIQUE(username)
);

CREATE TABLE sessions (
    session_ui_id   SERIAL          PRIMARY KEY,
    session_id      VARCHAR(36)     NOT NULL,
    active          BOOL            DEFAULT TRUE,

    UNIQUE(session_id)
);

CREATE TABLE session_hosts (
    session_host_ui_id  SERIAL      PRIMARY KEY,
    session_ui_id       INT         NOT NULL REFERENCES sessions(session_ui_id),
    user_ui_id          INTEGER     REFERENCES users(user_ui_id),

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_ui_id, address, agent)
);

CREATE TABLE api_keys (
    api_key_ui_id   SERIAL          PRIMARY KEY,
    user_ui_id      INTEGER         NOT NULL REFERENCES users(user_ui_id),
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(36)     NOT NULL,
    status          api_key_status  NOT NULL DEFAULT 'active',

    UNIQUE(value)
);

CREATE TABLE feeds (
    feed_ui_id      BIGSERIAL   PRIMARY KEY,
    user_ui_id      INTEGER     NOT NULL REFERENCES users(user_ui_id),
    api_key_ui_id   INTEGER     NOT NULL REFERENCES api_keys(api_key_ui_id),
    stamp           TIMESTAMP   NOT NULL DEFAULT now(),
    permissions     perms       NOT NULL DEFAULT 'private'
);

CREATE TABLE runs (
    run_ui_id       BIGSERIAL   PRIMARY KEY,
    feed_ui_id      BIGINT      NOT NULL REFERENCES feeds(feed_ui_id),

    permissions     perms       NOT NULL DEFAULT 'private',
    run_id          TEXT        NOT NULL,

    UNIQUE(feed_ui_id, run_id)
);

CREATE TABLE jobs (
    job_ui_id       BIGSERIAL   PRIMARY KEY,
    run_ui_id       BIGINT      NOT NULL REFERENCES runs(run_ui_id),

    permissions     perms       NOT NULL DEFAULT 'private',
    fail            BOOL        DEFAULT NULL,

    job_id          TEXT        NOT NULL,
    file            TEXT,

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
ALTER TABLE jobs ADD job_facet_ui_id BIGINT REFERENCES facets(facet_ui_id) UNIQUE;
ALTER TABLE jobs ADD end_facet_ui_id BIGINT REFERENCES facets(facet_ui_id) UNIQUE;

CREATE INDEX IF NOT EXISTS run_jobs          ON jobs   (run_ui_id);
CREATE INDEX IF NOT EXISTS job_events        ON events (job_ui_id);
CREATE INDEX IF NOT EXISTS facet_type_index  ON facets (facet_type);
CREATE INDEX IF NOT EXISTS facet_event_index ON facets (event_ui_id);

INSERT INTO users(username, pw_hash, pw_salt, is_admin) VALUES('root', 'Hffc/wurxNeSHmWeZOJ2SnlKNXy.QOy', 'j3rWkFXozdPaDKobXVV5u.', TRUE);
