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

CREATE TYPE tags AS ENUM(
    'other', -- Catch all for any not in this enum
    'ABOUT',
    'ARRAY',
    'BRIEF',
    'CONTROL',
    'CRITICAL',
    'DEBUG',
    'DIAG',
    'ENCODING',
    'ERROR',
    'FACETS',
    'FAIL',
    'FAILED',
    'FATAL',
    'HALT',
    'HARNESS',
    'KILL',
    'NO PLAN',
    'PASS',
    'PASSED',
    'PLAN',
    'REASON',
    'SHOW',
    'SKIP ALL',
    'SKIPPED',
    'STDERR',
    'TAGS',
    'TIMEOUT',
    'VERSION',
    'WARN',
    'WARNING'
);

CREATE TABLE config(
    config_id   BIGSERIAL       PRIMARY KEY,
    setting     VARCHAR(128)    NOT NULL,
    value       VARCHAR(256)    NOT NULL,

    UNIQUE(setting)
);

CREATE TABLE users (
    user_id     BIGSERIAL   NOT NULL PRIMARY KEY,
    username    CITEXT      NOT NULL,
    pw_hash     VARCHAR(31) DEFAULT NULL,
    pw_salt     VARCHAR(22) DEFAULT NULL,
    realname    TEXT        DEFAULT NULL,
    role        user_type   NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE email (
    email_id    BIGSERIAL   NOT NULL PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    local       CITEXT      NOT NULL,
    domain      CITEXT      NOT NULL,
    verified    BOOL        NOT NULL DEFAULT FALSE,

    UNIQUE(local, domain)
);
CREATE INDEX IF NOT EXISTS email_user ON email(user_id);

CREATE TABLE primary_email (
    user_id     BIGINT  NOT NULL REFERENCES users(user_id)  ON DELETE CASCADE PRIMARY KEY,
    email_id    BIGINT  NOT NULL REFERENCES email(email_id) ON DELETE CASCADE,

    unique(email_id)
);

CREATE TABLE hosts (
    host_id     BIGSERIAL       NOT NULL PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    email_id    BIGINT  NOT NULL REFERENCES email(email_id) ON DELETE CASCADE PRIMARY KEY,
    evcode      UUID    NOT NULL
);

CREATE TABLE sessions (
    session_id      BIGSERIAL   NOT NULL PRIMARY KEY,
    session_uuid    UUID        NOT NULL,
    active          BOOL        DEFAULT TRUE,

    UNIQUE(session_uuid)
);

CREATE TABLE session_hosts (
    session_host_id     BIGSERIAL   NOT NULL PRIMARY KEY,
    user_id             BIGINT      REFERENCES users(user_id) ON DELETE CASCADE,
    session_id          BIGINT      NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_id, address, agent)
);
CREATE INDEX IF NOT EXISTS session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_id  BIGSERIAL       NOT NULL PRIMARY KEY,
    user_id     BIGINT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name        VARCHAR(128)    NOT NULL,
    value       VARCHAR(36)     NOT NULL,
    status      api_key_status  NOT NULL DEFAULT 'active',

    UNIQUE(value)
);
CREATE INDEX IF NOT EXISTS api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     BIGSERIAL   NOT NULL PRIMARY KEY,
    name            TEXT        NOT NULL,
    local_file      TEXT,
    data            BYTEA
);

CREATE TABLE projects (
    project_id      BIGSERIAL   NOT NULL PRIMARY KEY,
    name            CITEXT      NOT NULL,
    owner           BIGINT      DEFAULT NULL REFERENCES users(user_id) ON DELETE SET NULL,

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   BIGSERIAL   NOT NULL PRIMARY KEY,
    project_id      BIGINT      NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    updated         TIMESTAMP   NOT NULL DEFAULT now(),

    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_id          BIGSERIAL       NOT NULL PRIMARY KEY,
    user_id         BIGINT          NOT NULL REFERENCES users(user_id)              ON DELETE CASCADE,
    project_id      BIGINT          NOT NULL REFERENCES projects(project_id)        ON DELETE CASCADE,
    log_file_id     BIGINT          DEFAULT NULL REFERENCES log_files(log_file_id)  ON DELETE SET NULL,

    run_uuid        UUID            NOT NULL,

    status          queue_status    NOT NULL DEFAULT 'pending',

    worker_id       TEXT            DEFAULT NULL,
    error           TEXT            DEFAULT NULL,

    pinned          BOOL            NOT NULL DEFAULT FALSE,

    -- FIXME
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,
    has_resources   BOOL            NOT NULL DEFAULT FALSE,

    -- FIXME: Do we need this?
    duration        TEXT            DEFAULT NULL,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    mode            run_modes       NOT NULL DEFAULT 'qvfd',
    buffer          run_buffering   NOT NULL DEFAULT 'job',

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,

    UNIQUE(run_uuid)
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project_id);
CREATE INDEX IF NOT EXISTS run_status   ON runs(status);
CREATE INDEX IF NOT EXISTS run_user     ON runs(user_id);

CREATE TABLE sweeps (
    sweep_id        BIGSERIAL       NOT NULL PRIMARY KEY,
    run_id          BIGINT          NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    name            VARCHAR(64)     NOT NULL,

    UNIQUE(run_id, name)
);
CREATE INDEX IF NOT EXISTS sweep_runs ON sweeps(run_id);

CREATE TABLE run_fields (
    run_field_id    BIGSERIAL       NOT NULL PRIMARY KEY,
    run_id          BIGINT          NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    run_field_uuid  UUID            NOT NULL,
    name            VARCHAR(64)     NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(run_field_uuid)
);
CREATE INDEX IF NOT EXISTS run_fields_run_id ON run_fields(run_id);
CREATE INDEX IF NOT EXISTS run_fields_name   ON run_fields(name);

CREATE TABLE run_parameters (
    run_id              BIGINT      NOT NULL PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE,
    parameters          JSONB       DEFAULT NULL
);

CREATE TABLE test_files (
    test_file_id    BIGSERIAL       NOT NULL PRIMARY KEY,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE jobs (
    job_id          BIGSERIAL           NOT NULL PRIMARY KEY,
    run_id          BIGINT              NOT NULL REFERENCES runs(run_id)                 ON DELETE CASCADE,
    test_file_id    BIGINT              DEFAULT NULL REFERENCES test_files(test_file_id) ON DELETE CASCADE,

    job_uuid        UUID                NOT NULL,
    job_try         INT                 NOT NULL,
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

    UNIQUE(job_uuid, job_try)
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_fail ON jobs(fail);
CREATE INDEX IF NOT EXISTS job_file ON jobs(test_file_id);

CREATE TABLE job_parameters (
    job_id              BIGINT      NOT NULL PRIMARY KEY REFERENCES jobs(job_id) ON DELETE CASCADE,
    parameters          JSONB       DEFAULT NULL
);

CREATE TABLE job_outputs (
    job_output_id   BIGSERIAL   NOT NULL PRIMARY KEY,
    job_id          BIGINT      NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    stream          io_stream   NOT NULL,
    output          TEXT        NOT NULL,

    UNIQUE(job_id, stream)
);

CREATE TABLE job_fields (
    job_field_id    BIGSERIAL       NOT NULL PRIMARY KEY,
    job_id          BIGINT          NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    job_field_uuid  UUID            NOT NULL,
    name            VARCHAR(64)     NOT NULL,
    data            JSONB           DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    UNIQUE(job_field_uuid)
);
CREATE INDEX IF NOT EXISTS job_fields_job_id ON job_fields(job_id);
CREATE INDEX IF NOT EXISTS job_fields_name   ON job_fields(name);

CREATE TABLE events (
    event_id        BIGSERIAL   NOT NULL PRIMARY KEY,

    job_id          BIGINT      NOT NULL     REFERENCES jobs(job_id)        ON DELETE CASCADE,
    parent_id       BIGINT      DEFAULT NULL REFERENCES events(event_id)    ON DELETE CASCADE,

    event_uuid      UUID        NOT NULL,
    trace_uuid      UUID        DEFAULT NULL,

    stamp           TIMESTAMP   NOT NULL,
    event_ord       INTEGER     NOT NULL,
    nested          SMALLINT    NOT NULL,

    is_subtest      BOOL        NOT NULL,
    is_diag         BOOL        NOT NULL,
    is_harness      BOOL        NOT NULL,
    is_time         BOOL        NOT NULL,
    is_assert       BOOL        NOT NULL,

    causes_fail     BOOL        NOT NULL,

    has_binary      BOOL        NOT NULL,
    has_facets      BOOL        NOT NULL,
    has_orphan      BOOL        NOT NULL,
    has_resources   BOOL        NOT NULL,

    UNIQUE(job_id, event_ord),
    UNIQUE(event_uuid)
);
CREATE INDEX IF NOT EXISTS event_job_ts ON events(job_id, stamp);
CREATE INDEX IF NOT EXISTS event_job_st ON events(job_id, is_subtest);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);
CREATE INDEX IF NOT EXISTS event_trace  ON events(trace_uuid);

CREATE TABLE renders (
    render_id   BIGSERIAL   NOT NULL PRIMARY KEY,
    job_id      BIGINT      NOT NULL REFERENCES jobs(job_id)     ON DELETE CASCADE,
    event_id    BIGINT      NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,

    facet       VARCHAR(64) NOT NULL,
    tag         tags        NOT NULL,

    other_tag   VARCHAR(8)  DEFAULT NULL,

    message     TEXT        NOT NULL,
    data        JSONB       DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS render_event      on renders(event_id);
CREATE INDEX IF NOT EXISTS render_job        on renders(job_id);
CREATE INDEX IF NOT EXISTS render_job_tag    on renders(job_id, tag);
CREATE INDEX IF NOT EXISTS render_job_ot_tag on renders(job_id, tag, other_tag);

CREATE TABLE facets (
    event_id    BIGINT      NOT NULL PRIMARY KEY REFERENCES events(event_id) ON DELETE CASCADE,
    data        JSONB       NOT NULL,
    line        BIGINT      NOT NULL,

    UNIQUE(event_id)
);

CREATE TABLE orphans (
    event_id    BIGINT      NOT NULL PRIMARY KEY REFERENCES events(event_id) ON DELETE CASCADE,
    data        JSONB       NOT NULL,
    line        BIGINT      NOT NULL,

    UNIQUE(event_id)
);

CREATE TABLE binaries (
    binary_id       BIGSERIAL       NOT NULL PRIMARY KEY,
    event_id        BIGINT          NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            BYTEA           NOT NULL
);
CREATE INDEX IF NOT EXISTS binaries_event ON binaries(event_id);

CREATE TABLE source_files (
    source_file_id  BIGSERIAL       NOT NULL PRIMARY KEY,
    filename        VARCHAR(512)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_id   BIGSERIAL       NOT NULL PRIMARY KEY,
    subname         VARCHAR(512)    NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE resource_types(
    resource_type_id    BIGSERIAL   NOT NULL PRIMARY KEY,
    name                TEXT        NOT NULL,

    UNIQUE(name)
);

CREATE TABLE resources (
    resource_id         BIGSERIAL   NOT NULL PRIMARY KEY,
    event_id            BIGINT      DEFAULT NULL REFERENCES events(event_id)       ON DELETE SET NULL,
    resource_type_id    BIGINT      NOT NULL     REFERENCES resources(resource_id) ON DELETE CASCADE,
    run_id              BIGINT      NOT NULL     REFERENCES runs(run_id)           ON DELETE CASCADE,

    data                JSONB       NOT NULL,
    line                BIGINT      NOT NULL,

    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS res_data_runs         ON resources(run_id);
CREATE INDEX IF NOT EXISTS res_data_res          ON resources(resource_type_id);
CREATE INDEX IF NOT EXISTS res_data_runs_and_res ON resources(run_id, resource_type_id);

CREATE TABLE coverage_manager (
    coverage_manager_id   BIGSERIAL     NOT NULL PRIMARY KEY,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    coverage_id             BIGSERIAL   NOT NULL PRIMARY KEY,

    -- FIXME: Make sure this gets imported
    event_id                BIGINT      DEFAULT NULL REFERENCES events(event_id)                        ON DELETE SET NULL,
    job_id                  BIGINT      DEFAULT NULL REFERENCES jobs(job_id)                            ON DELETE SET NULL,
    coverage_manager_id     BIGINT      DEFAULT NULL REFERENCES coverage_manager(coverage_manager_id)   ON DELETE CASCADE,

    run_id                  BIGINT      NOT NULL     REFERENCES runs(run_id)                            ON DELETE CASCADE,
    test_file_id            BIGINT      NOT NULL     REFERENCES test_files(test_file_id)                ON DELETE CASCADE,
    source_file_id          BIGINT      NOT NULL     REFERENCES source_files(source_file_id)            ON DELETE CASCADE,
    source_sub_id           BIGINT      NOT NULL     REFERENCES source_subs(source_sub_id)              ON DELETE CASCADE,

    metadata                JSONB       DEFAULT NULL,

    UNIQUE(run_id, job_id, test_file_id, source_file_id, source_sub_id)
);
CREATE INDEX IF NOT EXISTS coverage_from_source     ON coverage(source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_job        ON coverage(job_id);

CREATE TABLE reporting (
    reporting_id    BIGSERIAL           NOT NULL PRIMARY KEY,

    event_id        BIGINT              DEFAULT NULL REFERENCES events(event_id)            ON DELETE SET NULL,
    job_id          BIGINT              DEFAULT NULL REFERENCES jobs(job_id)                ON DELETE SET NULL,
    test_file_id    BIGINT              DEFAULT NULL REFERENCES test_files(test_file_id)    ON DELETE CASCADE,

    project_id      BIGINT              NOT NULL     REFERENCES projects(project_id)        ON DELETE CASCADE,
    user_id         BIGINT              NOT NULL     REFERENCES users(user_id)              ON DELETE CASCADE,
    run_id          BIGINT              NOT NULL     REFERENCES runs(run_id)                ON DELETE CASCADE,

    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT            NOT NULL DEFAULT 0,
    pass            SMALLINT            NOT NULL DEFAULT 0,
    retry           SMALLINT            NOT NULL DEFAULT 0,
    abort           SMALLINT            NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS reporting_run  ON reporting(run_id);
CREATE INDEX IF NOT EXISTS reporting_user ON reporting(user_id);
CREATE INDEX IF NOT EXISTS reporting_a    ON reporting(project_id);
CREATE INDEX IF NOT EXISTS reporting_b    ON reporting(project_id, user_id);
CREATE INDEX IF NOT EXISTS reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, reporting_id);
