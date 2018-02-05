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
    user_id         SERIAL          PRIMARY KEY,
    username        VARCHAR(32)     NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL,
    is_admin        BOOL            DEFAULT FALSE,

    UNIQUE(username)
);

CREATE TABLE sessions (
    session_id      SERIAL          PRIMARY KEY,
    session_val     VARCHAR(36)     NOT NULL,
    active          BOOL            DEFAULT TRUE,

    UNIQUE(session_id)
);

CREATE TABLE session_hosts (
    session_host_id     SERIAL      PRIMARY KEY,
    session_id          INT         NOT NULL REFERENCES sessions(session_id),
    user_id             INTEGER     REFERENCES users(user_id),

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_id, address, agent)
);

CREATE TABLE api_keys (
    api_key_id      SERIAL          PRIMARY KEY,
    user_id         INTEGER         NOT NULL REFERENCES users(user_id),
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(36)     NOT NULL,
    status          api_key_status  NOT NULL DEFAULT 'active',

    UNIQUE(value)
);

CREATE TABLE runs (
    run_id          BIGSERIAL   PRIMARY KEY,
    user_id         INTEGER     NOT NULL REFERENCES users(user_id),

    name            TEXT        NOT NULL,
    yath_run_id     TEXT        DEFAULT NULL,
    error           TEXT        DEFAULT NULL,
    added           TIMESTAMP   NOT NULL DEFAULT now(),

    permissions     perms       NOT NULL DEFAULT 'private',

    log_file        TEXT,
    status          queue_status    NOT NULL DEFAULT 'pending',

    UNIQUE(user_id, name)
);

CREATE TABLE jobs (
    job_id          BIGSERIAL   PRIMARY KEY,
    run_id          BIGINT      NOT NULL REFERENCES runs(run_id),

    yath_job_id     TEXT        NOT NULL,

    -- Summaries
    fail            BOOL        DEFAULT NULL,
    file            TEXT,

    UNIQUE(run_id, job_id)
);

CREATE TABLE events (
    event_id        BIGSERIAL   PRIMARY KEY,
    job_id          BIGINT      NOT NULL REFERENCES jobs(job_id),
    parent_id       BIGINT      REFERENCES events(event_id),

    stamp           TIMESTAMP   DEFAULT NULL,
    processed       TIMESTAMP   DEFAULT NULL,

    -- Summaries for lookup/display
    is_subtest      BOOL        NOT NULL,
    causes_fail     BOOL        NOT NULL,
    no_display      BOOL        NOT NULL,
    assert_pass     BOOL        DEFAULT NULL,
    plan_count      INTEGER     DEFAULT NULL,

    -- Standard Facets
    f_render        JSONB       DEFAULT NULL,
    f_about         JSONB       DEFAULT NULL,
    f_amnesty       JSONB       DEFAULT NULL,
    f_assert        JSONB       DEFAULT NULL,
    f_control       JSONB       DEFAULT NULL,
    f_error         JSONB       DEFAULT NULL,
    f_info          JSONB       DEFAULT NULL,
    f_meta          JSONB       DEFAULT NULL,
    f_parent        JSONB       DEFAULT NULL,
    f_plan          JSONB       DEFAULT NULL,
    f_trace         JSONB       DEFAULT NULL,

    -- Harness Facets
    f_harness               JSONB   DEFAULT NULL,
    f_harness_job           JSONB   DEFAULT NULL,
    f_harness_job_end       JSONB   DEFAULT NULL,
    f_harness_job_exit      JSONB   DEFAULT NULL,
    f_harness_job_launch    JSONB   DEFAULT NULL,
    f_harness_job_start     JSONB   DEFAULT NULL,
    f_harness_run           JSONB   DEFAULT NULL,

    -- The rest
    f_other         JSONB       DEFAULT NULL
);

CREATE TABLE event_links (
    event_link_id       BIGSERIAL   PRIMARY KEY,

    job_id              BIGINT      NOT NULL REFERENCES jobs(job_id),
    yath_eid            TEXT        NOT NULL,
    trace_hid           TEXT        NOT NULL,

    buffered_proc_id    BIGINT      REFERENCES events(event_id),
    unbuffered_proc_id  BIGINT      REFERENCES events(event_id),
    buffered_raw_id     BIGINT      REFERENCES events(event_id),
    unbuffered_raw_id   BIGINT      REFERENCES events(event_id),

    UNIQUE(job_id, yath_eid, trace_hid)
);

CREATE INDEX IF NOT EXISTS run_jobs      ON jobs   (run_id);
CREATE INDEX IF NOT EXISTS events_job_id ON events (job_id);

-- Password is 'root'
INSERT INTO users(username, pw_hash, pw_salt, is_admin) VALUES('root', 'Hffc/wurxNeSHmWeZOJ2SnlKNXy.QOy', 'j3rWkFXozdPaDKobXVV5u.', TRUE);
