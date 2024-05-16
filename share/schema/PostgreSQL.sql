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

CREATE TYPE io_stream AS ENUM(
    'STDOUT',
    'STDERR'
);

CREATE TABLE config(
    config_idx  BIGSERIAL       PRIMARY KEY,
    setting     VARCHAR(128)    NOT NULL,
    value       VARCHAR(256)    NOT NULL,

    UNIQUE(setting)
);

CREATE TABLE users (
    user_idx    BIGSERIAL   NOT NULL PRIMARY KEY,
    username    CITEXT      NOT NULL,
    pw_hash     VARCHAR(31) DEFAULT NULL,
    pw_salt     VARCHAR(22) DEFAULT NULL,
    realname    TEXT        DEFAULT NULL,
    role        user_type   NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE email (
    email_idx   BIGSERIAL   NOT NULL PRIMARY KEY,
    user_idx    BIGINT      NOT NULL REFERENCES users(user_idx) ON DELETE CASCADE,
    local       CITEXT      NOT NULL,
    domain      CITEXT      NOT NULL,
    verified    BOOL        NOT NULL DEFAULT FALSE,

    UNIQUE(local, domain)
);
CREATE INDEX IF NOT EXISTS email_user ON email(user_idx);

CREATE TABLE primary_email (
    user_idx    BIGINT  NOT NULL REFERENCES users(user_idx) ON DELETE CASCADE PRIMARY KEY,
    email_idx   BIGINT  NOT NULL REFERENCES email(email_idx) ON DELETE CASCADE,

    unique(email_idx)
);

CREATE TABLE hosts (
    host_idx    BIGSERIAL       NOT NULL PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    email_idx   BIGINT  NOT NULL REFERENCES email(email_idx) ON DELETE CASCADE PRIMARY KEY,
    evcode      UUID    NOT NULL
);

CREATE TABLE sessions (
    session_id  UUID    NOT NULL PRIMARY KEY,
    active      BOOL    DEFAULT TRUE
);

CREATE TABLE session_hosts (
    session_host_idx    BIGSERIAL   NOT NULL PRIMARY KEY,
    user_idx            BIGINT      REFERENCES users(user_idx) ON DELETE CASCADE,
    session_id          UUID        NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_id, address, agent)
);
CREATE INDEX IF NOT EXISTS session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_idx BIGSERIAL       NOT NULL PRIMARY KEY,
    user_idx    BIGINT          NOT NULL REFERENCES users(user_idx) ON DELETE CASCADE,
    name        VARCHAR(128)    NOT NULL,
    value       VARCHAR(36)     NOT NULL,
    status      api_key_status  NOT NULL DEFAULT 'active',

    UNIQUE(value)
);
CREATE INDEX IF NOT EXISTS api_key_user ON api_keys(user_idx);

CREATE TABLE log_files (
    log_file_idx    BIGSERIAL   NOT NULL PRIMARY KEY,
    name            TEXT        NOT NULL,
    local_file      TEXT,
    data            BYTEA
);

CREATE TABLE projects (
    project_idx     BIGSERIAL   NOT NULL PRIMARY KEY,
    name            CITEXT      NOT NULL,
    owner           BIGINT      DEFAULT NULL REFERENCES users(user_idx) ON DELETE SET NULL,

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_idx  BIGSERIAL       NOT NULL PRIMARY KEY,
    project_idx     BIGINT          NOT NULL REFERENCES projects(project_idx) ON DELETE CASCADE,
    user_idx        BIGINT          NOT NULL REFERENCES users(user_idx) ON DELETE CASCADE,
    updated         TIMESTAMP       NOT NULL DEFAULT now(),

    UNIQUE(project_idx, user_idx)
);

CREATE TABLE runs (
    run_idx         BIGSERIAL       NOT NULL PRIMARY KEY,
    user_idx        BIGINT          NOT NULL REFERENCES users(user_idx) ON DELETE CASCADE,
    project_idx     BIGINT          NOT NULL REFERENCES projects(project_idx) ON DELETE CASCADE,
    log_file_idx    BIGINT          DEFAULT NULL REFERENCES log_files(log_file_idx) ON DELETE SET NULL,

    run_id          UUID            NOT NULL,

    status          queue_status    NOT NULL DEFAULT 'pending',

    worker_id       TEXT            DEFAULT NULL,
    error           TEXT            DEFAULT NULL,

    pinned          BOOL            NOT NULL DEFAULT FALSE,
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    duration        TEXT            DEFAULT NULL,
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    buffer          run_buffering   NOT NULL DEFAULT 'job',

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,

    UNIQUE(run_id)
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project_idx);
CREATE INDEX IF NOT EXISTS run_status   ON runs(status);
CREATE INDEX IF NOT EXISTS run_user     ON runs(user_idx);

CREATE TABLE sweeps (
    sweep_idx       BIGSERIAL       NOT NULL PRIMARY KEY,
    run_idx         BIGINT          NOT NULL REFERENCES runs(run_idx) ON DELETE CASCADE,
    name            VARCHAR(255)    NOT NULL,

    UNIQUE(run_idx, name)
);
CREATE INDEX IF NOT EXISTS sweep_runs ON sweeps(run_idx);

CREATE TABLE run_fields (
    run_field_idx   BIGSERIAL       NOT NULL PRIMARY KEY,
    run_field_id    UUID            NOT NULL,
    run_id          UUID            NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    name            VARCHAR(255)    NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(run_field_id)
);
CREATE INDEX IF NOT EXISTS run_fields_run_id ON run_fields(run_id);
CREATE INDEX IF NOT EXISTS run_fields_name   ON run_fields(name);

CREATE TABLE run_parameters (
    run_parameters_idx  BIGSERIAL   NOT NULL PRIMARY KEY,
    run_id              UUID        NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    parameters          JSONB       DEFAULT NULL,

    UNIQUE(run_id)
);

CREATE TABLE test_files (
    test_file_idx   BIGSERIAL       NOT NULL PRIMARY KEY,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE jobs (
    job_idx         BIGSERIAL           NOT NULL PRIMARY KEY,

    job_key         UUID                NOT NULL,
    job_id          UUID                NOT NULL,
    run_id          UUID                NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,

    test_file_idx   BIGINT              DEFAULT NULL REFERENCES test_files(test_file_idx) ON DELETE CASCADE,

    job_try         INT                 NOT NULL DEFAULT 0,
    status          queue_status        NOT NULL DEFAULT 'pending',

    is_harness_out  BOOL                NOT NULL DEFAULT FALSE,

    -- Summaries
    fail            BOOL                DEFAULT NULL,
    retry           BOOL                DEFAULT NULL,
    name            TEXT                DEFAULT NULL,
    exit_code       INT                 DEFAULT NULL,
    launch          TIMESTAMP           DEFAULT NULL,
    start           TIMESTAMP           DEFAULT NULL,
    ended           TIMESTAMP           DEFAULT NULL,

    duration        DOUBLE PRECISION    DEFAULT NULL,

    pass_count      BIGINT              DEFAULT NULL,
    fail_count      BIGINT              DEFAULT NULL,

    UNIQUE(job_key),
    UNIQUE(job_id, job_try)
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_fail ON jobs(fail);
CREATE INDEX IF NOT EXISTS job_file ON jobs(test_file_idx);

CREATE TABLE job_parameters (
    job_parameters_idx  BIGSERIAL   NOT NULL PRIMARY KEY,
    job_key             UUID        NOT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,
    parameters          JSONB       DEFAULT NULL,

    UNIQUE(job_key)
);

CREATE TABLE job_outputs (
    job_output_idx  BIGSERIAL   NOT NULL PRIMARY KEY,
    job_key         UUID        NOT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,
    stream          io_stream   NOT NULL,
    output          TEXT        NOT NULL,

    UNIQUE(job_key, stream)
);

CREATE TABLE job_fields (
    job_field_idx   BIGSERIAL       NOT NULL PRIMARY KEY,
    job_field_id    UUID            NOT NULL,
    job_key         UUID            NOT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,
    name            VARCHAR(512)    NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(job_field_id)
);
CREATE INDEX IF NOT EXISTS job_fields_job_key ON job_fields(job_key);
CREATE INDEX IF NOT EXISTS job_fields_name    ON job_fields(name);

CREATE TABLE events (
    event_idx   BIGSERIAL   NOT NULL PRIMARY KEY,
    event_id    UUID        NOT NULL,

    job_key     UUID        NOT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,

    is_subtest  BOOL        NOT NULL,
    is_diag     BOOL        NOT NULL,
    is_harness  BOOL        NOT NULL,
    is_time     BOOL        NOT NULL,
    is_assert   BOOL        NOT NULL,

    causes_fail BOOL        NOT NULL,

    has_binary  BOOL        NOT NULL,
    has_facets  BOOL        NOT NULL,
    has_orphan  BOOL        NOT NULL,

    stamp       TIMESTAMP   DEFAULT NULL,

    parent_id   UUID        DEFAULT NULL, -- REFERENCES events(event_id),
    trace_id    UUID        DEFAULT NULL,
    nested      INT         NOT NULL DEFAULT 0,

    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS event_job_ts ON events(job_key, stamp);
CREATE INDEX IF NOT EXISTS event_job_st ON events(job_key, is_subtest);
CREATE INDEX IF NOT EXISTS event_trace  ON events(trace_id);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);

CREATE TABLE renders (
    event_id    UUID        NOT NULL PRIMARY KEY REFERENCES events(event_id) ON DELETE CASCADE,
    data        JSONB       DEFAULT NULL,

    UNIQUE(event_id)
);

CREATE TABLE facets (
    event_id    UUID        NOT NULL PRIMARY KEY REFERENCES events(event_id) ON DELETE CASCADE,
    data        JSONB       DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    UNIQUE(event_id)
);

CREATE TABLE orphans (
    event_id    UUID        NOT NULL PRIMARY KEY REFERENCES events(event_id) ON DELETE CASCADE,
    data        JSONB       DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    UNIQUE(event_id)
);

CREATE TABLE binaries (
    binary_idx      BIGSERIAL       NOT NULL PRIMARY KEY,
    event_id        UUID            NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            BYTEA           NOT NULL
);
CREATE INDEX IF NOT EXISTS binaries_event ON binaries(event_id);

CREATE TABLE source_files (
    source_file_idx BIGSERIAL       NOT NULL PRIMARY KEY,
    filename        VARCHAR(512)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_idx  BIGSERIAL       NOT NULL PRIMARY KEY,
    subname         VARCHAR(512)    NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE coverage_manager (
    coverage_manager_idx  BIGSERIAL     NOT NULL PRIMARY KEY,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    coverage_idx            BIGSERIAL   NOT NULL PRIMARY KEY,

    run_id                  UUID        NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    job_key                 UUID        DEFAULT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,

    test_file_idx           BIGINT      NOT NULL REFERENCES test_files(test_file_idx) ON DELETE CASCADE,
    source_file_idx         BIGINT      NOT NULL REFERENCES source_files(source_file_idx) ON DELETE CASCADE,
    source_sub_idx          BIGINT      NOT NULL REFERENCES source_subs(source_sub_idx) ON DELETE CASCADE,
    coverage_manager_idx    BIGINT      DEFAULT NULL REFERENCES coverage_manager(coverage_manager_idx) ON DELETE CASCADE,

    metadata                JSONB       DEFAULT NULL,

    UNIQUE(run_id, job_key, test_file_idx, source_file_idx, source_sub_idx)
);
CREATE INDEX IF NOT EXISTS coverage_from_source     ON coverage(source_file_idx, source_sub_idx);
CREATE INDEX IF NOT EXISTS coverage_from_run_source ON coverage(run_id, source_file_idx, source_sub_idx);
CREATE INDEX IF NOT EXISTS coverage_from_job        ON coverage(job_key);

CREATE TABLE reporting (
    reporting_idx   BIGSERIAL           NOT NULL PRIMARY KEY,

    project_idx     BIGINT              NOT NULL     REFERENCES projects(project_idx) ON DELETE CASCADE,
    user_idx        BIGINT              NOT NULL     REFERENCES users(user_idx) ON DELETE CASCADE,
    run_id          UUID                NOT NULL     REFERENCES runs(run_id) ON DELETE CASCADE,

    test_file_idx   BIGINT              DEFAULT NULL REFERENCES test_files(test_file_idx) ON DELETE CASCADE,
    job_key         UUID                DEFAULT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,
    event_id        UUID                DEFAULT NULL REFERENCES events(event_id) ON DELETE CASCADE,

    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT            NOT NULL DEFAULT 0,
    pass            SMALLINT            NOT NULL DEFAULT 0,
    retry           SMALLINT            NOT NULL DEFAULT 0,
    abort           SMALLINT            NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS reporting_user ON reporting(user_idx);
CREATE INDEX IF NOT EXISTS reporting_run  ON reporting(run_id);
CREATE INDEX IF NOT EXISTS reporting_a    ON reporting(project_idx);
CREATE INDEX IF NOT EXISTS reporting_b    ON reporting(project_idx, user_idx);
CREATE INDEX IF NOT EXISTS reporting_e    ON reporting(project_idx, test_file_idx, subtest, user_idx, reporting_idx);

CREATE TABLE resource_batch (
    resource_batch_idx  BIGSERIAL       PRIMARY KEY,
    run_id              UUID            NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    host_idx            BIGINT          NOT NULL REFERENCES hosts(host_idx) ON DELETE CASCADE,
    stamp               TIMESTAMP(4)    NOT NULL
);
CREATE INDEX IF NOT EXISTS resource_batch_run ON resource_batch(run_id);

CREATE TABLE resources (
    resource_idx        BIGSERIAL       NOT NULL PRIMARY KEY,
    resource_batch_idx  BIGINT          NOT NULL REFERENCES resource_batch(resource_batch_idx) ON DELETE CASCADE,
    module              VARCHAR(512)    NOT NULL,
    data                JSONB           NOT NULL
);
CREATE INDEX IF NOT EXISTS resources_batch_idx ON resources(resource_batch_idx);
