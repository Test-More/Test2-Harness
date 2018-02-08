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

CREATE TABLE users (
    user_id         SERIAL          PRIMARY KEY,
    username        VARCHAR(32)     NOT NULL,
    pw_hash         VARCHAR(31)     NOT NULL,
    pw_salt         VARCHAR(22)     NOT NULL,
    is_admin        BOOL            DEFAULT FALSE,

    UNIQUE(username)
);

CREATE TABLE sessions (
    session_id      VARCHAR(36)     PRIMARY KEY,
    active          BOOL            DEFAULT TRUE
);

CREATE TABLE session_hosts (
    session_host_id     SERIAL      PRIMARY KEY,
    session_id          VARCHAR(36) NOT NULL REFERENCES sessions(session_id),
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

    parameters      JSONB       DEFAULT NULL,
    error           TEXT        DEFAULT NULL,
    added           TIMESTAMP   NOT NULL DEFAULT now(),

    permissions     perms           NOT NULL DEFAULT 'private',
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    store_facets    store_toggle    NOT NULL DEFAULT 'fail',
    store_orphans   store_toggle    NOT NULL DEFAULT 'fail',

    log_file        TEXT,
    status          queue_status    NOT NULL DEFAULT 'pending',

    UNIQUE(user_id, name)
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

CREATE TABLE event_lines (
    event_line_id   BIGSERIAL   PRIMARY KEY,
    event_id        UUID        NOT NULL REFERENCES events(event_id),

    tag             VARCHAR(8)  NOT NULL,
    facet           VARCHAR(32) NOT NULL,
    content         TEXT        DEFAULT NULL,
    content_json    JSONB       DEFAULT NULL
);

-- Password is 'root'
INSERT INTO users(username, pw_hash, pw_salt, is_admin) VALUES('root', 'Hffc/wurxNeSHmWeZOJ2SnlKNXy.QOy', 'j3rWkFXozdPaDKobXVV5u.', TRUE);
