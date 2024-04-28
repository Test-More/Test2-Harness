CREATE EXTENSION "citext";
CREATE EXTENSION "uuid-ossp";

CREATE TYPE queue_status AS ENUM(
    'pending',
    'running',
    'complete',
    'broken',
    'canceled'
);

CREATE TYPE api_key_status AS ENUM(
    'active',
    'disabled',
    'revoked'
);

CREATE TYPE run_modes AS ENUM(
    'summary',
    'qvfds',
    'qvfd',
    'qvf',
    'complete'
);

CREATE TYPE run_buffering AS ENUM(
    'none',
    'diag',
    'job',
    'run'
);

CREATE TYPE user_type AS ENUM(
    'admin',    -- Can add users and set permissions
    'user'     -- Can manage reports for their projects
);

CREATE TABLE users (
    user_id         UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    username        CITEXT          NOT NULL,
    pw_hash         VARCHAR(31)     DEFAULT NULL,
    pw_salt         VARCHAR(22)     DEFAULT NULL,
    realname        TEXT            DEFAULT NULL,
    role            user_type       NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE email (
    email_id        UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    user_id         UUID            NOT NULL REFERENCES users(user_id),
    local           CITEXT          NOT NULL,
    domain          CITEXT          NOT NULL,
    verified        BOOL            NOT NULL DEFAULT FALSE,

    UNIQUE(local, domain)
);
CREATE INDEX IF NOT EXISTS email_user ON email(user_id);

CREATE TABLE primary_email (
    user_id         UUID            NOT NULL REFERENCES users(user_id) PRIMARY KEY,
    email_id        UUID            NOT NULL REFERENCES email(email_id),

    unique(email_id)
);

CREATE TABLE hosts (
    host_id     UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    evcode_id       UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    email_id        UUID            NOT NULL REFERENCES email(email_id),

    unique(email_id)
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
    local_file      TEXT,
    data            BYTEA
);

CREATE TABLE projects (
    project_id      UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    name            CITEXT          NOT NULL,
    owner           UUID            DEFAULT NULL REFERENCES users(user_id),

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    project_id      UUID            NOT NULL REFERENCES projects(project_id),
    user_id         UUID            NOT NULL REFERENCES users(user_id),
    updated         TIMESTAMP       NOT NULL DEFAULT now(),

    cpan_batch      BIGINT          DEFAULT NULL,

    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_id          UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    run_ord         BIGSERIAL       NOT NULL,
    user_id         UUID            NOT NULL REFERENCES users(user_id),
    status          queue_status    NOT NULL DEFAULT 'pending',
    worker_id       TEXT            DEFAULT NULL,
    error           TEXT            DEFAULT NULL,
    project_id      UUID            NOT NULL REFERENCES projects(project_id),

    pinned          BOOL            NOT NULL DEFAULT FALSE,
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    duration        TEXT            DEFAULT NULL,
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    buffer          run_buffering   NOT NULL DEFAULT 'job',
    log_file_id     UUID            DEFAULT NULL REFERENCES log_files(log_file_id),

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,
    parameters      JSONB           DEFAULT NULL,

    UNIQUE(run_ord)
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project_id);
CREATE INDEX IF NOT EXISTS run_status ON runs(status);
CREATE INDEX IF NOT EXISTS run_user ON runs(user_id);

CREATE TABLE sweeps (
    sweep_id        UUID            NOT NULL PRIMARY KEY,
    run_id          UUID            NOT NULL REFERENCES runs(run_id),
    name            VARCHAR(255)    NOT NULL,

    UNIQUE(run_id, name)
);
CREATE INDEX IF NOT EXISTS sweep_runs ON sweeps(run_id);

CREATE TABLE run_fields (
    run_field_id    UUID            NOT NULL PRIMARY KEY,
    run_id          UUID            NOT NULL REFERENCES runs(run_id),
    name            VARCHAR(255)    NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(run_id, name)
);

CREATE TABLE test_files (
    test_file_id    UUID            NOT NULL PRIMARY KEY,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE jobs (
    job_key         UUID        NOT NULL PRIMARY KEY,

    job_id          UUID        NOT NULL,
    job_try         INT         NOT NULL DEFAULT 0,
    job_ord         BIGINT      NOT NULL,
    run_id          UUID        NOT NULL REFERENCES runs(run_id),

    is_harness_out  BOOL        NOT NULL DEFAULT FALSE,

    status          queue_status    NOT NULL DEFAULT 'pending',
    parameters      JSONB           DEFAULT NULL,

    test_file_id    UUID            DEFAULT NULL REFERENCES test_files(test_file_id),

    -- Summaries
    name            TEXT            DEFAULT NULL,
    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    exit_code       INT             DEFAULT NULL,
    launch          TIMESTAMP       DEFAULT NULL,
    start           TIMESTAMP       DEFAULT NULL,
    ended           TIMESTAMP       DEFAULT NULL,

    duration        DOUBLE PRECISION    DEFAULT NULL,

    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    -- Output data
    stdout          TEXT            DEFAULT NULL,
    stderr          TEXT            DEFAULT NULL,

    UNIQUE(job_id, job_try)
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_fail ON jobs(fail);
CREATE INDEX IF NOT EXISTS job_file ON jobs(test_file_id);

CREATE TABLE job_fields (
    job_field_id    UUID            NOT NULL PRIMARY KEY,
    job_key         UUID            NOT NULL REFERENCES jobs(job_key),
    name            VARCHAR(512)    NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(job_key, name)
);

CREATE TABLE events (
    event_id        UUID        NOT NULL PRIMARY KEY,

    job_key         UUID        NOT NULL REFERENCES jobs(job_key),

    event_ord       BIGINT      NOT NULL,
    insert_ord      BIGSERIAL   NOT NULL,

    is_subtest      BOOL        NOT NULL DEFAULT FALSE,
    is_diag         BOOL        NOT NULL DEFAULT FALSE,
    is_harness      BOOL        NOT NULL DEFAULT FALSE,
    is_time         BOOL        NOT NULL DEFAULT FALSE,
    has_binary      BOOL        NOT NULL DEFAULT FALSE,

    stamp           TIMESTAMP   DEFAULT NULL,

    parent_id       UUID        DEFAULT NULL, -- REFERENCES events(event_id),
    trace_id        UUID        DEFAULT NULL,
    nested          INT         DEFAULT 0,

    facets          JSONB       DEFAULT NULL,
    facets_line     BIGINT      DEFAULT NULL,

    orphan          JSONB       DEFAULT NULL,
    orphan_line     BIGINT      DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS event_job    ON events(job_key);
CREATE INDEX IF NOT EXISTS event_trace  ON events(trace_id);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);
CREATE INDEX IF NOT EXISTS is_subtest   ON events(is_subtest);

CREATE TABLE binaries (
    binary_id       UUID            NOT NULL PRIMARY KEY,
    event_id        UUID            NOT NULL REFERENCES events(event_id),
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            BYTEA           NOT NULL
);
CREATE INDEX IF NOT EXISTS binaries_event ON binaries(event_id);

CREATE TABLE source_files (
    source_file_id  UUID            NOT NULL PRIMARY KEY,
    filename        VARCHAR(512)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_id   UUID            NOT NULL PRIMARY KEY,
    subname         VARCHAR(512)    NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE coverage_manager (
    coverage_manager_id   UUID          NOT NULL PRIMARY KEY,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    coverage_id     UUID    NOT NULL PRIMARY KEY,

    run_id              UUID    NOT NULL REFERENCES runs(run_id),
    test_file_id        UUID    NOT NULL REFERENCES test_files(test_file_id),
    source_file_id      UUID    NOT NULL REFERENCES source_files(source_file_id),
    source_sub_id       UUID    NOT NULL REFERENCES source_subs(source_sub_id),
    coverage_manager_id UUID    DEFAULT NULL REFERENCES coverage_manager(coverage_manager_id),
    job_key             UUID    DEFAULT NULL REFERENCES jobs(job_key),

    metadata    JSONB   DEFAULT NULL,

    UNIQUE(run_id, test_file_id, source_file_id, source_sub_id, job_key)
);
CREATE INDEX IF NOT EXISTS coverage_from_source ON coverage(source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_job ON coverage(job_key);

CREATE TABLE reporting (
    reporting_id    UUID                DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    run_ord         BIGINT              NOT NULL,
    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT    NOT NULL DEFAULT 0,
    pass            SMALLINT    NOT NULL DEFAULT 0,
    retry           SMALLINT    NOT NULL DEFAULT 0,
    abort           SMALLINT    NOT NULL DEFAULT 0,

    project_id      UUID    NOT NULL     REFERENCES projects(project_id),
    run_id          UUID    NOT NULL     REFERENCES runs(run_id),
    user_id         UUID    NOT NULL     REFERENCES users(user_id),
    job_key         UUID    DEFAULT NULL REFERENCES jobs(job_key),
    test_file_id    UUID    DEFAULT NULL REFERENCES test_files(test_file_id),
    event_id        UUID    DEFAULT NULL REFERENCES events(event_id)
);
CREATE INDEX IF NOT EXISTS reporting_user ON reporting(user_id);
CREATE INDEX IF NOT EXISTS reporting_run  ON reporting(run_id);
CREATE INDEX IF NOT EXISTS reporting_a    ON reporting(project_id);
CREATE INDEX IF NOT EXISTS reporting_b    ON reporting(project_id, user_id);
CREATE INDEX IF NOT EXISTS reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, run_ord);

CREATE TABLE resource_batch (
    resource_batch_id   UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    run_id              UUID            NOT NULL REFERENCES runs(run_id),
    host_id             UUID            NOT NULL REFERENCES hosts(host_id),
    stamp               TIMESTAMP(4)    NOT NULL
);
CREATE INDEX IF NOT EXISTS resource_batch_run ON resource_batch(run_id);

CREATE TABLE resources (
    resource_id         UUID            DEFAULT UUID_GENERATE_V4() PRIMARY KEY,
    resource_batch_id   UUID            NOT NULL REFERENCES resource_batch(resource_batch_id),
    batch_ord           INT             NOT NULL,
    module              VARCHAR(512)    NOT NULL,
    data                JSONB           NOT NULL,

    UNIQUE(resource_batch_id, batch_ord)
);
