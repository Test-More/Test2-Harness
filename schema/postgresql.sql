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

CREATE TYPE run_modes AS ENUM(
    'summary',
    'qvfd',
    'qvf',
    'complete'
);

CREATE TYPE store_toggle AS ENUM(
    'yes',
    'no',
    'fail'
);

CREATE TYPE user_type AS ENUM(
    'admin',    -- Can add users
    'user',     -- Can view their own runs, protected runs, and shared runs
    'bot',      -- Can request signoffs
    'uploader'  -- Can upload public runs and view them
);

CREATE TABLE users (
    user_id         SERIAL          PRIMARY KEY,
    username        VARCHAR(32)     NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL,
    role            user_type       NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE sessions (
    session_id      UUID     PRIMARY KEY,
    active          BOOL     DEFAULT TRUE
);

CREATE TABLE session_hosts (
    session_host_id     SERIAL      PRIMARY KEY,
    session_id          UUID        NOT NULL REFERENCES sessions(session_id),
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

CREATE TABLE projects (
    project_id      BIGSERIAL   PRIMARY KEY,
    name            TEXT        NOT NULL,

    UNIQUE(name)
);

CREATE TABLE runs (
    run_id          BIGSERIAL   PRIMARY KEY,
    user_id         INTEGER     NOT NULL REFERENCES users(user_id),

    name            TEXT        DEFAULT NULL,

    project_id      BIGINT      NOT NULL REFERENCES projects(project_id),
    version         TEXT        NOT NULL,

    parameters      JSONB       DEFAULT NULL,
    error           TEXT        DEFAULT NULL,
    added           TIMESTAMP   NOT NULL DEFAULT now(),

    need_signoff    BOOL            NOT NULL DEFAULT FALSE,
    persist_events  BOOL            NOT NULL DEFAULT FALSE,
    pinned          BOOL            NOT NULL DEFAULT FALSE,
    permissions     perms           NOT NULL DEFAULT 'private',
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    store_facets    store_toggle    NOT NULL DEFAULT 'fail',
    store_orphans   store_toggle    NOT NULL DEFAULT 'fail',

    log_file        TEXT            NOT NULL,
    log_data        BYTEA           DEFAULT NULL,
    status          queue_status    NOT NULL DEFAULT 'pending'
);

CREATE TABLE run_comments (
    run_comment_id  BIGSERIAL   NOT NULL PRIMARY KEY,
    user_id         INTEGER     NOT NULL REFERENCES users(user_id),
    created         TIMESTAMP   NOT NULL DEFAULT now(),
    content         TEXT        NOT NULL
);

CREATE TABLE run_shares (
    run_share_id    BIGSERIAL   NOT NULL PRIMARY KEY,
    run_id          BIGINT      NOT NULL REFERENCES runs(run_id),
    user_id         INTEGER     NOT NULL REFERENCES users(user_id),
    pinned          BOOL        NOT NULL DEFAULT FALSE,
    created         TIMESTAMP   NOT NULL DEFAULT now(),

    UNIQUE(run_id, user_id)
);

CREATE TABLE jobs (
    job_id          UUID        NOT NULL PRIMARY KEY,
    job_ord         BIGINT      NOT NULL,
    run_id          BIGINT      NOT NULL REFERENCES runs(run_id),

    parameters      JSONB       DEFAULT NULL,

    -- Summaries
    name            TEXT        NOT NULL,
    file            TEXT        DEFAULT NULL,
    fail            BOOL        DEFAULT NULL,
    exit            INT         DEFAULT NULL,
    launch          TIMESTAMP   DEFAULT NULL,
    start           TIMESTAMP   DEFAULT NULL,
    ended           TIMESTAMP   DEFAULT NULL
);

CREATE TABLE job_signoffs (
    job_signoff_id  BIGSERIAL   PRIMARY KEY,
    job_id          UUID        NOT NULL REFERENCES jobs(job_id),
    user_id         INTEGER     NOT NULL REFERENCES users(user_id),
    note            TEXT        DEFAULT NULL,
    created         TIMESTAMP   NOT NULL DEFAULT now(),
    UNIQUE(job_id, user_id)
);

CREATE TABLE events (
    event_id        UUID        NOT NULL PRIMARY KEY,
    event_ord       BIGINT      NOT NULL,
    job_id          UUID        NOT NULL REFERENCES jobs(job_id),
    parent_id       UUID        DEFAULT NULL REFERENCES events(event_id),

    -- Summaries for lookup/display

    nested          INT         NOT NULL,
    causes_fail     BOOL        NOT NULL,

    no_render       BOOL        NOT NULL,
    no_display      BOOL        NOT NULL,

    is_parent       BOOL        NOT NULL,
    is_assert       BOOL        NOT NULL,
    is_plan         BOOL        NOT NULL,
    is_diag         BOOL        NOT NULL,
    is_orphan       BOOL        NOT NULL,

    assert_pass     BOOL        DEFAULT NULL,
    plan_count      INTEGER     DEFAULT NULL,

    facets          JSONB       DEFAULT NULL
);

CREATE TABLE event_comments (
    event_comment_id    BIGSERIAL   NOT NULL PRIMARY KEY,
    user_id             INTEGER     NOT NULL REFERENCES users(user_id),
    created             TIMESTAMP   NOT NULL DEFAULT now(),
    content             TEXT        NOT NULL
);

CREATE TABLE event_lines (
    event_line_id   BIGSERIAL   PRIMARY KEY,
    event_id        UUID        NOT NULL REFERENCES events(event_id),

    tag             VARCHAR(8)  NOT NULL,
    facet           VARCHAR(32) NOT NULL,
    content         TEXT        DEFAULT NULL,
    content_json    JSONB       DEFAULT NULL
);

-- Password is 'root'
INSERT INTO users(username, pw_hash, pw_salt, role) VALUES('root', 'Hffc/wurxNeSHmWeZOJ2SnlKNXy.QOy', 'j3rWkFXozdPaDKobXVV5u.', 'admin');
