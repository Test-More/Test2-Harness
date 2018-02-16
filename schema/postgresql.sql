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

CREATE TABLE runs (
    run_id          UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    user_id         UUID            NOT NULL REFERENCES users(user_id),

    name            TEXT            DEFAULT NULL,

    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,

    project         CITEXT          DEFAULT NULL,
    version         CITEXT          DEFAULT NULL,

    parameters      JSONB           DEFAULT NULL,
    error           TEXT            DEFAULT NULL,
    added           TIMESTAMP       NOT NULL DEFAULT now(),

    persist_events  BOOL            NOT NULL DEFAULT FALSE,
    permissions     perms           NOT NULL DEFAULT 'private',
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    store_facets    store_toggle    NOT NULL DEFAULT 'fail',
    store_orphans   store_toggle    NOT NULL DEFAULT 'fail',

    log_file        TEXT            NOT NULL,
    log_data        BYTEA           NOT NULL,
    status          queue_status    NOT NULL DEFAULT 'pending'
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project);
CREATE INDEX IF NOT EXISTS run_status ON runs(status);
CREATE INDEX IF NOT EXISTS run_user ON runs(user_id);
CREATE INDEX IF NOT EXISTS run_perms ON runs(permissions);
CREATE INDEX IF NOT EXISTS run_user_perms ON runs(user_id, permissions);

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

CREATE TABLE dashboards (
    dashboard_id        UUID        DEFAULT UUID_GENERATE_V4() NOT NULL PRIMARY KEY,
    user_id             UUID        NOT NULL REFERENCES users(user_id),

    is_public           BOOL        DEFAULT NULL,

    name                TEXT        NOT NULL,

    weight              SMALLINT    NOT NULL DEFAULT 0,

    show_passes         BOOL        NOT NULL,
    show_failures       BOOL        NOT NULL,
    show_pending        BOOL        NOT NULL,
    show_shared         BOOL        NOT NULL,
    show_mine           BOOL        NOT NULL,
    show_protected      BOOL        NOT NULL,
    show_public         BOOL        NOT NULL,
    show_signoff_only   BOOL        NOT NULL,
    show_errors_only    BOOL        NOT NULL,

    show_columns        JSONB       NOT NULL,

    show_project        CITEXT      DEFAULT NULL,
    show_version        CITEXT      DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS dashboard_user ON dashboards(user_id);

CREATE TABLE jobs (
    job_id          UUID        NOT NULL PRIMARY KEY,
    job_ord         BIGINT      NOT NULL,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),

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
CREATE INDEX IF NOT EXISTS event_job ON events(job_id);

CREATE TABLE event_comments (
    event_comment_id    UUID        DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    event_id            UUID        NOT NULL REFERENCES events(event_id),
    user_id             UUID        NOT NULL REFERENCES users(user_id),
    created             TIMESTAMP   NOT NULL DEFAULT now(),
    content             TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS event_comment_event ON event_comments(event_id);

CREATE TABLE event_lines (
    event_line_id   UUID        DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    event_id        UUID        NOT NULL REFERENCES events(event_id),

    tag             VARCHAR(8)  NOT NULL,
    facet           VARCHAR(32) NOT NULL,
    content         TEXT        DEFAULT NULL,
    content_json    JSONB       DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS event_lines_event ON event_lines(event_id);
