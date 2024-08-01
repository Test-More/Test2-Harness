CREATE TABLE versions(
    version_id  INTEGER         NOT NULL    PRIMARY KEY AUTOINCREMENT,
    version     NUMERIC(10,6)   NOT NULL,
    updated     DATETIME(6)     NOT NULL    DEFAULT now,

    UNIQUE(version)
);

INSERT INTO versions(version) VALUES('2.000000');

CREATE TABLE config(
    config_id   INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    setting     VARCHAR(128)    NOT NULL,
    value       VARCHAR(256)    NOT NULL,

    UNIQUE(setting)
);

CREATE TABLE users (
    user_id     INTEGER     NOT NULL        PRIMARY KEY AUTOINCREMENT,
    pw_hash     VARCHAR(31) DEFAULT NULL,
    pw_salt     VARCHAR(22) DEFAULT NULL,

    role TEXT CHECK(role IN (
        'admin',    -- Can add users and set permissions
        'user'      -- Can manage reports for their projects
    )) NOT NULL DEFAULT 'user',

    username    VARCHAR(64) NOT NULL,
    realname    TEXT        DEFAULT NULL,

    UNIQUE(username)
);

CREATE TABLE email (
    email_id    INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER         NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    verified    BOOL            NOT NULL DEFAULT FALSE,

    local       VARCHAR(128)    NOT NULL,
    domain      VARCHAR(128)    NOT NULL,

    UNIQUE(local, domain)
);
CREATE INDEX IF NOT EXISTS email_user ON email(user_id);

CREATE TABLE primary_email (
    user_id     BIGINT  NOT NULL PRIMARY KEY REFERENCES users(user_id)  ON DELETE CASCADE,
    email_id    BIGINT  NOT NULL             REFERENCES email(email_id) ON DELETE CASCADE,

    unique(email_id)
);

CREATE TABLE hosts (
    host_id     INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    evcode      UUID    NOT NULL,
    email_id    BIGINT  NOT NULL PRIMARY KEY REFERENCES email(email_id) ON DELETE CASCADE
);

CREATE TABLE sessions (
    session_id      INTEGER     NOT NULL    PRIMARY KEY AUTOINCREMENT,
    session_uuid    UUID        NOT NULL,
    active          BOOL                    DEFAULT TRUE,

    UNIQUE(session_uuid)
);

CREATE TABLE session_hosts (
    session_host_id     INTEGER     NOT NULL PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER              REFERENCES users(user_id)       ON DELETE CASCADE,
    session_id          INTEGER     NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,

    created             DATETIME(6) NOT NULL DEFAULT now,
    accessed            DATETIME(6) NOT NULL DEFAULT now,

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(address, agent, session_id)
);
CREATE INDEX IF NOT EXISTS session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_id  INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    value       UUID            NOT NULL,
    user_id     INTEGER         NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,

    status      TEXT            NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'disabled', 'revoked')),

    name        VARCHAR(128)    NOT NULL,

    UNIQUE(value)
);
CREATE INDEX IF NOT EXISTS api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     INTEGER     NOT NULL PRIMARY KEY AUTOINCREMENT,
    name            TEXT        NOT NULL,
    local_file      TEXT,
    data            LONGBLOB
);

CREATE TABLE projects (
    project_id      INTEGER         NOT NULL        PRIMARY KEY AUTOINCREMENT,
    owner           INTEGER         DEFAULT NULL    REFERENCES users(user_id) ON DELETE SET NULL,
    name            VARCHAR(128)    NOT NULL,

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   INTEGER     NOT NULL PRIMARY KEY AUTOINCREMENT,
    project_id      INTEGER     NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    user_id         INTEGER     NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    updated         DATETIME(6) NOT NULL DEFAULT now,

    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_uuid        UUID            NOT NULL,

    run_id          INTEGER         NOT NULL        PRIMARY KEY AUTOINCREMENT,
    user_id         INTEGER         NOT NULL        REFERENCES users(user_id)          ON DELETE CASCADE,
    project_id      INTEGER         NOT NULL        REFERENCES projects(project_id)    ON DELETE CASCADE,
    log_file_id     INTEGER         DEFAULT NULL    REFERENCES log_files(log_file_id)  ON DELETE SET NULL,

    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    to_retry        INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency_j   INTEGER         DEFAULT NULL,
    concurrency_x   INTEGER         DEFAULT NULL,
    added           DATETIME(6)     NOT NULL        DEFAULT now,

    status          TEXT            CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled'))
                                    DEFAULT 'pending' NOT NULL,

    mode            TEXT            CHECK(mode IN ('qvfds', 'qvfd', 'qvf', 'summary', 'complete'))
                                    DEFAULT 'qvfd' NOT NULL,

    canon           BOOL            NOT NULL,
    pinned          BOOL            NOT NULL        DEFAULT FALSE,
    has_coverage    BOOL            DEFAULT NULL,
    has_resources   BOOL            DEFAULT NULL,

    parameters      JSON            DEFAULT NULL,
    worker_id       TEXT            DEFAULT NULL,
    error           TEXT            DEFAULT NULL,
    duration        NUMERIC(14,4)   DEFAULT NULL,

    UNIQUE(run_uuid)
);
CREATE INDEX IF NOT EXISTS run_projects ON runs(project_id);
CREATE INDEX IF NOT EXISTS run_status   ON runs(status);
CREATE INDEX IF NOT EXISTS run_user     ON runs(user_id);
CREATE INDEX IF NOT EXISTS run_canon    ON runs(run_id, canon);

CREATE TABLE sweeps (
    sweep_id        INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER         NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    name            VARCHAR(64)     NOT NULL,

    UNIQUE(run_id, name)
);
CREATE INDEX IF NOT EXISTS sweep_runs ON sweeps(run_id);

CREATE TABLE test_files (
    test_file_id    INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

INSERT INTO test_files(filename) VALUES('HARNESS INTERNAL LOG');

CREATE TABLE jobs (
    job_uuid        UUID        NOT NULL,

    job_id          INTEGER     NOT NULL    PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER     NOT NULL    REFERENCES runs(run_id)             ON DELETE CASCADE,
    test_file_id    INTEGER     NOT NULL    REFERENCES test_files(test_file_id) ON DELETE CASCADE,

    is_harness_out  BOOL        NOT NULL,
    failed          BOOL        NOT NULL,
    passed          BOOL        DEFAULT NULL,

    UNIQUE(job_uuid)
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_file ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_uuid    UUID            NOT NULL,
    job_try_id      INTEGER         NOT NULL    PRIMARY KEY AUTOINCREMENT,
    job_id          INTEGER         NOT NULL    REFERENCES jobs(job_id) ON DELETE CASCADE,
    pass_count      INTEGER         DEFAULT NULL,
    fail_count      INTEGER         DEFAULT NULL,

    exit_code       INTEGER         DEFAULT NULL,
    launch          DATETIME(6)     DEFAULT NULL,
    start           DATETIME(6)     DEFAULT NULL,
    ended           DATETIME(6)     DEFAULT NULL,

    status          TEXT            CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled'))
                                    DEFAULT 'pending' NOT NULL,

    job_try_ord     SMALLINTEGER    NOT NULL,

    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    duration        NUMERIC(14,4)   DEFAULT NULL,

    parameters      JSON            DEFAULT NULL,
    stdout          TEXT            DEFAULT NULL,
    stderr          TEXT            DEFAULT NULL,

    UNIQUE(job_try_id, job_try_ord)
);
CREATE INDEX IF NOT EXISTS job_try_fail     ON job_tries(fail);
CREATE INDEX IF NOT EXISTS job_try_job_fail ON job_tries(job_id, fail);

CREATE TABLE events (
    event_uuid      UUID        NOT NULL,
    trace_uuid      UUID        DEFAULT NULL,
    parent_uuid     UUID        DEFAULT NULL    REFERENCES events(event_uuid),

    event_id        INTEGER     NOT NULL        PRIMARY KEY AUTOINCREMENT,
    job_try_id      INTEGER     NOT NULL        REFERENCES job_tries(job_try_id) ON DELETE CASCADE,
    parent_id       INTEGER     DEFAULT NULL    REFERENCES events(event_id)      ON DELETE CASCADE,

    event_idx       INTEGER     NOT NULL, -- Line number from log, or event number from stream
    event_sdx       INTEGER     NOT NULL, -- Event sequence number from the line (IE parent + subtest events)
    stamp           DATETIME(6) DEFAULT NULL,

    nested          SMALLINTEGERNOT NULL,

    is_subtest      BOOL        NOT NULL,
    is_diag         BOOL        NOT NULL,
    is_harness      BOOL        NOT NULL,
    is_time         BOOL        NOT NULL,
    is_orphan       BOOL        NOT NULL,

    causes_fail     BOOL        NOT NULL,

    has_facets      BOOL        NOT NULL,
    has_binary      BOOL        NOT NULL,

    facets          JSON        DEFAULT NULL,
    rendered        JSON        DEFAULT NULL,

    UNIQUE(job_try_id, event_idx, event_sdx),
    UNIQUE(event_uuid)
);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);
CREATE INDEX IF NOT EXISTS event_job_ts ON events(job_try_id, stamp);
CREATE INDEX IF NOT EXISTS event_job_st ON events(job_try_id, is_subtest);

CREATE TABLE binaries (
    event_uuid      UUID            NOT NULL,

    binary_id       INTEGER         NOT NULL        PRIMARY KEY AUTOINCREMENT,
    event_id        INTEGER         DEFAULT NULL    REFERENCES events(event_id) ON DELETE CASCADE,

    is_image        BOOL            NOT NULL DEFAULT FALSE,

    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    data            LONGBLOB        NOT NULL
);
CREATE INDEX IF NOT EXISTS binaries_event ON binaries(event_id);

CREATE TABLE run_fields (
    event_uuid      UUID            NOT NULL,

    run_field_id    INTEGER         NOT NULL    PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER         NOT NULL    REFERENCES runs(run_id)     ON DELETE CASCADE,

    name            VARCHAR(64)     NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS run_fields_run_id ON run_fields(run_id);
CREATE INDEX IF NOT EXISTS run_fields_name   ON run_fields(name);

CREATE TABLE job_try_fields (
    event_uuid          UUID            NOT NULL,

    job_try_field_id    INTEGER         NOT NULL    PRIMARY KEY AUTOINCREMENT,
    job_try_id          INTEGER         NOT NULL    REFERENCES job_tries(job_try_id) ON DELETE CASCADE,

    name                VARCHAR(64)     NOT NULL,
    data                JSON            DEFAULT NULL,
    details             TEXT            DEFAULT NULL,
    raw                 TEXT            DEFAULT NULL,
    link                TEXT            DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS job_try_fields_job_id ON job_try_fields(job_try_id);
CREATE INDEX IF NOT EXISTS job_try_fields_name   ON job_try_fields(name);

CREATE TABLE source_files (
    source_file_id  INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    filename        VARCHAR(512)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_id   INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    subname         VARCHAR(512)    NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE resource_types(
    resource_type_id    INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    name                VARCHAR(512)    NOT NULL,

    UNIQUE(name)
);

CREATE TABLE resources (
    event_uuid          UUID        NOT NULL,

    resource_id         INTEGER     NOT NULL    PRIMARY KEY AUTOINCREMENT,
    resource_type_id    INTEGER     NOT NULL    REFERENCES resource_types(resource_type_id) ON DELETE CASCADE,
    run_id              INTEGER     NOT NULL    REFERENCES runs(run_id)                     ON DELETE CASCADE,
    host_id             INTEGER                 REFERENCES hosts(host_id)                   ON DELETE SET NULL,

    stamp               DATETIME(6) NOT NULL,
    resource_ord        INTEGER     NOT NULL,

    data                JSON        NOT NULL,

    UNIQUE(run_id, resource_ord)
);
CREATE INDEX IF NOT EXISTS res_data_runs         ON resources(run_id);
CREATE INDEX IF NOT EXISTS res_data_run_ords     ON resources(run_id, resource_ord);
CREATE INDEX IF NOT EXISTS res_data_res          ON resources(resource_type_id);
CREATE INDEX IF NOT EXISTS res_data_runs_and_res ON resources(run_id, resource_type_id);

CREATE TABLE coverage_manager (
    coverage_manager_id   INTEGER       NOT NULL PRIMARY KEY AUTOINCREMENT,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    event_uuid              UUID        NOT NULL,

    coverage_id             INTEGER     NOT NULL        PRIMARY KEY AUTOINCREMENT,

    job_try_id              INTEGER     DEFAULT NULL    REFERENCES job_tries(job_try_id)                   ON DELETE SET NULL,
    coverage_manager_id     INTEGER     DEFAULT NULL    REFERENCES coverage_manager(coverage_manager_id)   ON DELETE CASCADE,

    run_id                  INTEGER     NOT NULL        REFERENCES runs(run_id)                            ON DELETE CASCADE,
    test_file_id            INTEGER     NOT NULL        REFERENCES test_files(test_file_id)                ON DELETE CASCADE,
    source_file_id          INTEGER     NOT NULL        REFERENCES source_files(source_file_id)            ON DELETE CASCADE,
    source_sub_id           INTEGER     NOT NULL        REFERENCES source_subs(source_sub_id)              ON DELETE CASCADE,

    metadata                JSON        DEFAULT NULL,

    UNIQUE(run_id, job_try_id, test_file_id, source_file_id, source_sub_id)
);
CREATE INDEX IF NOT EXISTS coverage_from_source     ON coverage(source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_job        ON coverage(job_try_id);

CREATE TABLE reporting (
    reporting_id    INTEGER         NOT NULL        PRIMARY KEY AUTOINCREMENT,

    job_try_id      INTEGER         DEFAULT NULL    REFERENCES job_tries(job_try_id)       ON DELETE SET NULL,
    test_file_id    INTEGER         DEFAULT NULL    REFERENCES test_files(test_file_id)    ON DELETE CASCADE,

    project_id      INTEGER         NOT NULL        REFERENCES projects(project_id)        ON DELETE CASCADE,
    user_id         INTEGER         NOT NULL        REFERENCES users(user_id)              ON DELETE CASCADE,
    run_id          INTEGER         NOT NULL        REFERENCES runs(run_id)                ON DELETE CASCADE,

    job_try         SMALLINTEGER    DEFAULT NULL,

    retry           SMALLINTEGER    NOT NULL,
    abort           SMALLINTEGER    NOT NULL,
    fail            SMALLINTEGER    NOT NULL,
    pass            SMALLINTEGER    NOT NULL,

    subtest         VARCHAR(512)    DEFAULT NULL,
    duration        NUMERIC(14,4)   NOT NULL
);
CREATE INDEX IF NOT EXISTS reporting_run  ON reporting(run_id);
CREATE INDEX IF NOT EXISTS reporting_user ON reporting(user_id);
CREATE INDEX IF NOT EXISTS reporting_a    ON reporting(project_id);
CREATE INDEX IF NOT EXISTS reporting_b    ON reporting(project_id, user_id);
CREATE INDEX IF NOT EXISTS reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, reporting_id);
