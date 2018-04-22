CREATE EXTENSION "citext";
CREATE EXTENSION "uuid-ossp";

CREATE TYPE perms AS ENUM(
    'private',
    'protected',
    'public'
);

CREATE TYPE queue_status AS ENUM(
    'pending',
    'running',
    'complete',
    'broken'
);

CREATE TYPE api_key_status AS ENUM(
    'active',
    'disabled',
    'revoked'
);

CREATE TYPE run_modes AS ENUM(
    'summary',
    'qvfd',
    'qvf',
    'complete'
);

CREATE TYPE user_type AS ENUM(
    'admin',    -- Can add users
    'user',     -- Can view their own runs, protected runs, and shared runs
    'bot',      -- Can request signoffs
    'uploader'  -- Can upload public runs and view them
);

CREATE TABLE users (
    user_id         UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    username        CITEXT          NOT NULL,
    email           CITEXT          DEFAULT NULL,
    slack           CITEXT          DEFAULT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL,
    role            user_type       NOT NULL DEFAULT 'user',

    UNIQUE(username),
    UNIQUE(slack),
    UNIQUE(email)
);

CREATE TABLE sessions (
    session_id      UUID     DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    active          BOOL     DEFAULT TRUE
);

CREATE TABLE session_hosts (
    session_host_id     UUID        DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    session_id          UUID        NOT NULL REFERENCES sessions(session_id),
    user_id             UUID        REFERENCES users(user_id),

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_id, address, agent)
);
CREATE INDEX IF NOT EXISTS session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_id      UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    user_id         UUID            NOT NULL REFERENCES users(user_id),
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(36)     NOT NULL,
    status          api_key_status  NOT NULL DEFAULT 'active',

    UNIQUE(value)
);
CREATE INDEX IF NOT EXISTS api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    name            TEXT            NOT NULL,
    data            BYTEA           NOT NULL
);

CREATE TABLE runs (
    run_id          UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    user_id         UUID            NOT NULL REFERENCES users(user_id),
    status          queue_status    NOT NULL DEFAULT 'pending',
    error           TEXT            DEFAULT NULL,

    -- User Input
    project         CITEXT          NOT NULL,
    version         CITEXT          DEFAULT NULL,
    tier            CITEXT          DEFAULT NULL,
    category        CITEXT          DEFAULT NULL,
    build           CITEXT          DEFAULT NULL,
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    permissions     perms           NOT NULL DEFAULT 'private',
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    log_file_id     UUID            DEFAULT NULL REFERENCES log_files(log_file_id),

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    parameters      JSONB           DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project);
CREATE INDEX IF NOT EXISTS run_status ON runs(status);
CREATE INDEX IF NOT EXISTS run_user ON runs(user_id);
CREATE INDEX IF NOT EXISTS run_perms ON runs(permissions);

CREATE TABLE signoffs (
    run_id          UUID            NOT NULL PRIMARY KEY REFERENCES runs(run_id),
    requested_by    UUID            NOT NULL REFERENCES users(user_id),
    completed       TIMESTAMP       DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS signoff_completed ON signoffs(completed);

CREATE TABLE run_comments (
    run_comment_id  UUID        DEFAULT UUID_GENERATE_V4() NOT NULL PRIMARY KEY,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),
    user_id         UUID        NOT NULL REFERENCES users(user_id),
    created         TIMESTAMP   NOT NULL DEFAULT now(),
    content         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS run_comment_run ON run_comments(run_id);

CREATE TABLE run_shares (
    run_share_id    UUID        DEFAULT UUID_GENERATE_V4() NOT NULL PRIMARY KEY,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),
    user_id         UUID        NOT NULL REFERENCES users(user_id),

    UNIQUE(run_id, user_id)
);
CREATE INDEX IF NOT EXISTS run_share_user ON run_shares(user_id);

CREATE TABLE run_pins (
    run_pin_id      UUID        DEFAULT UUID_GENERATE_V4() NOT NULL PRIMARY KEY,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),
    user_id         UUID        NOT NULL REFERENCES users(user_id)
);
CREATE INDEX IF NOT EXISTS run_pin_user ON run_pins(user_id);
CREATE INDEX IF NOT EXISTS run_pin_run  ON run_pins(run_id);

CREATE TABLE jobs (
    job_id          UUID        NOT NULL PRIMARY KEY,
    job_ord         BIGINT      NOT NULL,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),

    parameters      JSONB       DEFAULT NULL,

    -- Summaries
    name            TEXT            DEFAULT NULL,
    file            TEXT            DEFAULT NULL,
    fail            BOOL            DEFAULT NULL,
    exit            INT             DEFAULT NULL,
    launch          TIMESTAMP       DEFAULT NULL,
    start           TIMESTAMP       DEFAULT NULL,
    ended           TIMESTAMP       DEFAULT NULL,

    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    -- Process time data
    time_user       DECIMAL(20,10)  DEFAULT NULL,
    time_sys        DECIMAL(20,10)  DEFAULT NULL,
    time_cuser      DECIMAL(20,10)  DEFAULT NULL,
    time_csys       DECIMAL(20,10)  DEFAULT NULL,

    -- Process memory data
    mem_peak        BIGINT          DEFAULT NULL,
    mem_size        BIGINT          DEFAULT NULL,
    mem_rss         BIGINT          DEFAULT NULL,
    mem_peak_u      VARCHAR(2)      DEFAULT NULL,
    mem_size_u      VARCHAR(2)      DEFAULT NULL,
    mem_rss_u       VARCHAR(2)      DEFAULT NULL,

    -- Output data
    stdout          TEXT            DEFAULT NULL,
    stderr          TEXT            DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_fail ON jobs(fail);
CREATE INDEX IF NOT EXISTS job_file ON jobs(file);

CREATE TABLE job_signoffs (
    job_signoff_id  UUID        DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    job_id          UUID        NOT NULL REFERENCES jobs(job_id),
    user_id         UUID        NOT NULL REFERENCES users(user_id),
    note            TEXT        DEFAULT NULL,
    created         TIMESTAMP   NOT NULL DEFAULT now(),
    UNIQUE(job_id, user_id)
);
CREATE INDEX IF NOT EXISTS job_signoff_job ON job_signoffs(job_id);

CREATE TABLE events (
    event_id        UUID        NOT NULL PRIMARY KEY,
    job_id          UUID        NOT NULL REFERENCES jobs(job_id),

    event_ord       BIGINT      NOT NULL,

    stamp           TIMESTAMP   DEFAULT NULL,

    parent_id       UUID        DEFAULT NULL REFERENCES events(event_id),
    trace_id        UUID        DEFAULT NULL,
    nested          INT         DEFAULT 0,

    facets          JSONB       DEFAULT NULL,
    facets_line     BIGINT      DEFAULT NULL,

    orphan          JSONB       DEFAULT NULL,
    orphan_line     BIGINT      DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS event_job    ON events(job_id);
CREATE INDEX IF NOT EXISTS event_trace  ON events(trace_id);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);

CREATE TABLE event_comments (
    event_comment_id    UUID        DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    event_id            UUID        NOT NULL REFERENCES events(event_id),
    user_id             UUID        NOT NULL REFERENCES users(user_id),
    created             TIMESTAMP   NOT NULL DEFAULT now(),
    content             TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS event_comment_event ON event_comments(event_id);
