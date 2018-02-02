CREATE TYPE perms AS ENUM(
    'private',
    'protected',
    'public'
);

CREATE TYPE queue_status AS ENUM(
    'pending',
    'running',
    'complete',
    'failed'
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

    name            TEXT        NOT NULL,
    orig_file       TEXT        NOT NULL,
    local_file      TEXT        NOT NULL,
    error           TEXT        DEFAULT NULL,
    stamp           TIMESTAMP   NOT NULL DEFAULT now(),

    permissions     perms           NOT NULL DEFAULT 'private',
    status          queue_status    NOT NULL DEFAULT 'pending',

    UNIQUE(user_ui_id, name)
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

    job_id          TEXT        NOT NULL,

    -- Summaries
    fail            BOOL        DEFAULT NULL,
    file            TEXT,

    UNIQUE(run_ui_id, job_id)
);

CREATE TABLE events (
    event_ui_id     BIGSERIAL   PRIMARY KEY,
    job_ui_id       BIGSERIAL   NOT NULL REFERENCES jobs(job_ui_id),

    -- Event fields
    event_id        TEXT        NOT NULL,
    stream_id       TEXT        DEFAULT NULL,
    stamp           TIMESTAMP   DEFAULT NULL,
    processed       TIMESTAMP   DEFAULT NULL,

    -- Summaries for easy lookup
    causes_fail     BOOL        NOT NULL,
    assert_pass     BOOL        DEFAULT NULL,
    plan_count      BIGINT      DEFAULT NULL,
    in_hid          TEXT        DEFAULT NULL,
    is_hid          TEXT        DEFAULT NULL,

    -- Standard Facets
    about           JSONB       DEFAULT NULL,
    amnesty         JSONB       DEFAULT NULL,
    assert          JSONB       DEFAULT NULL,
    control         JSONB       DEFAULT NULL,
    error           JSONB       DEFAULT NULL,
    info            JSONB       DEFAULT NULL,
    meta            JSONB       DEFAULT NULL,
    parent          JSONB       DEFAULT NULL,
    plan            JSONB       DEFAULT NULL,
    trace           JSONB       DEFAULT NULL,

    -- Harness Facets
    harness             JSONB   DEFAULT NULL,
    harness_job         JSONB   DEFAULT NULL,
    harness_job_end     JSONB   DEFAULT NULL,
    harness_job_exit    JSONB   DEFAULT NULL,
    harness_job_launch  JSONB   DEFAULT NULL,
    harness_job_start   JSONB   DEFAULT NULL,
    harness_run         JSONB   DEFAULT NULL,

    -- The rest
    other_facets    JSONB       DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS run_jobs     ON jobs   (run_ui_id);
CREATE INDEX IF NOT EXISTS job_events   ON events (job_ui_id);
CREATE INDEX IF NOT EXISTS subtests     ON events (is_hid);
CREATE INDEX IF NOT EXISTS children     ON events (in_hid);

INSERT INTO users(username, pw_hash, pw_salt, is_admin) VALUES('root', 'Hffc/wurxNeSHmWeZOJ2SnlKNXy.QOy', 'j3rWkFXozdPaDKobXVV5u.', TRUE);
