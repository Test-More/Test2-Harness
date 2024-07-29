CREATE TABLE versions(
    version     NUMERIC(10,6)   NOT NULL,
    version_id  INT             NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    updated     TIMESTAMP(6)    NOT NULL    DEFAULT now(),

    UNIQUE(version)
);

INSERT INTO versions(version) VALUES('2.000000');

CREATE TABLE config(
    config_id   INT             NOT NULL PRIMARY KEY AUTO_INCREMENT,
    setting     VARCHAR(128)    NOT NULL,
    value       VARCHAR(256)    NOT NULL,

    UNIQUE(setting)
);

CREATE TABLE users (
    user_id     BIGINT      NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    pw_hash     VARCHAR(31) DEFAULT NULL,
    pw_salt     VARCHAR(22) DEFAULT NULL,

    role        ENUM('admin', 'user')
                            NOT NULL        DEFAULT 'user',

    username    VARCHAR(64) NOT NULL,
    realname    TEXT        DEFAULT NULL,

    UNIQUE(username)
);

CREATE TABLE email (
    email_id    BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    user_id     BIGINT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
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
    host_id     BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    evcode      UUID    NOT NULL,
    email_id    BIGINT  NOT NULL PRIMARY KEY REFERENCES email(email_id) ON DELETE CASCADE
);

CREATE TABLE sessions (
    session_uuid    UUID        NOT NULL,
    session_id      BIGINT      NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    active          BOOL                    DEFAULT TRUE,

    UNIQUE(session_uuid)
);

CREATE TABLE session_hosts (
    session_host_id     BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    user_id             BIGINT                   REFERENCES users(user_id)       ON DELETE CASCADE,
    session_id          BIGINT          NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,

    created             TIMESTAMP(6)    NOT NULL DEFAULT now(),
    accessed            TIMESTAMP(6)    NOT NULL DEFAULT now(),

    address             TEXT            NOT NULL,
    agent               TEXT            NOT NULL,

    UNIQUE(address, agent, session_id)
);
CREATE INDEX IF NOT EXISTS session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    value       UUID            NOT NULL,
    api_key_id  BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    user_id     BIGINT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,

    status      ENUM( 'active', 'disabled', 'revoked')
                                NOT NULL DEFAULT 'active',

    name        VARCHAR(128)    NOT NULL,

    UNIQUE(value)
);
CREATE INDEX IF NOT EXISTS api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     BIGINT      NOT NULL PRIMARY KEY AUTO_INCREMENT,
    name            TEXT        NOT NULL,
    local_file      TEXT,
    data            LONGBLOB
);

CREATE TABLE projects (
    project_id      BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    owner           BIGINT          DEFAULT NULL    REFERENCES users(user_id) ON DELETE SET NULL,
    name            VARCHAR(128)    NOT NULL,

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    project_id      BIGINT          NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    user_id         BIGINT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    updated         TIMESTAMP(6)    NOT NULL DEFAULT now(),

    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_uuid        UUID            NOT NULL,

    run_id          BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    user_id         BIGINT          NOT NULL        REFERENCES users(user_id)          ON DELETE CASCADE,
    project_id      BIGINT          NOT NULL        REFERENCES projects(project_id)    ON DELETE CASCADE,
    log_file_id     BIGINT          DEFAULT NULL    REFERENCES log_files(log_file_id)  ON DELETE SET NULL,

    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    to_retry        INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency_j   INTEGER         DEFAULT NULL,
    concurrency_x   INTEGER         DEFAULT NULL,
    added           TIMESTAMP(6)    NOT NULL        DEFAULT now(),

    status          ENUM('pending', 'running', 'complete', 'broken', 'canceled')
                                    NOT NULL        DEFAULT 'pending',

    mode            ENUM('qvfds', 'qvfd', 'qvf', 'summary', 'complete')
                                    NOT NULL        DEFAULT 'qvfd',

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
    sweep_id        BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT          NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    name            VARCHAR(64)     NOT NULL,

    UNIQUE(run_id, name)
);
CREATE INDEX IF NOT EXISTS sweep_runs ON sweeps(run_id);

CREATE TABLE test_files (
    test_file_id    BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

INSERT INTO test_files(filename) VALUES('HARNESS INTERNAL LOG');

CREATE TABLE jobs (
    job_uuid        UUID        NOT NULL,

    job_id          BIGINT      NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT      NOT NULL    REFERENCES runs(run_id)             ON DELETE CASCADE,
    test_file_id    BIGINT      NOT NULL    REFERENCES test_files(test_file_id) ON DELETE CASCADE,

    is_harness_out  BOOL        NOT NULL,
    failed          BOOL        NOT NULL,
    passed          BOOL        DEFAULT NULL,

    UNIQUE(job_uuid)
);
CREATE INDEX IF NOT EXISTS job_runs ON jobs(run_id);
CREATE INDEX IF NOT EXISTS job_file ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_uuid    UUID            NOT NULL,
    job_try_id      BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    job_id          BIGINT          NOT NULL    REFERENCES jobs(job_id) ON DELETE CASCADE,
    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    exit_code       INTEGER         DEFAULT NULL,
    launch          TIMESTAMP(6)    DEFAULT NULL,
    start           TIMESTAMP(6)    DEFAULT NULL,
    ended           TIMESTAMP(6)    DEFAULT NULL,


    status          ENUM('pending', 'running', 'complete', 'broken', 'canceled')
                                    NOT NULL    DEFAULT 'pending',

    job_try_ord     SMALLINT        NOT NULL,

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
    event_uuid      UUID            NOT NULL,
    trace_uuid      UUID            DEFAULT NULL,
    parent_uuid     UUID            DEFAULT NULL    REFERENCES events(event_uuid),

    event_id        BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    job_try_id      BIGINT          NOT NULL        REFERENCES job_tries(job_try_id) ON DELETE CASCADE,
    parent_id       BIGINT          DEFAULT NULL    REFERENCES events(event_id)      ON DELETE CASCADE,

    event_idx       INTEGER         NOT NULL, -- Line number from log, or event number from stream
    event_sdx       INTEGER         NOT NULL, -- Event sequence number from the line (IE parent + subtest events)
    stamp           TIMESTAMP(6)    DEFAULT NULL,

    nested          SMALLINT        NOT NULL,

    is_subtest      BOOL            NOT NULL,
    is_diag         BOOL            NOT NULL,
    is_harness      BOOL            NOT NULL,
    is_time         BOOL            NOT NULL,
    is_orphan       BOOL            NOT NULL,

    causes_fail     BOOL            NOT NULL,

    has_facets      BOOL            NOT NULL,
    has_binary      BOOL            NOT NULL,

    facets          JSON            DEFAULT NULL,
    rendered        JSON            DEFAULT NULL,

    UNIQUE(job_try_id, event_idx, event_sdx),
    UNIQUE(event_uuid)
);
CREATE INDEX IF NOT EXISTS event_parent ON events(parent_id);
CREATE INDEX IF NOT EXISTS event_job_ts ON events(job_try_id, stamp);
CREATE INDEX IF NOT EXISTS event_job_st ON events(job_try_id, is_subtest);

CREATE TABLE binaries (
    event_uuid      UUID            NOT NULL,

    binary_id       BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    event_id        BIGINT          DEFAULT NULL    REFERENCES events(event_id) ON DELETE CASCADE,

    is_image        BOOL            NOT NULL DEFAULT FALSE,

    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    data            LONGBLOB        NOT NULL
);
CREATE INDEX IF NOT EXISTS binaries_event ON binaries(event_id);

CREATE TABLE run_fields (
    event_uuid      UUID            NOT NULL,

    run_field_id    BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT          NOT NULL    REFERENCES runs(run_id)     ON DELETE CASCADE,

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

    job_try_field_id    BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    job_try_id          BIGINT          NOT NULL     REFERENCES job_tries(job_try_id) ON DELETE CASCADE,

    name                VARCHAR(64)     NOT NULL,
    data                JSON            DEFAULT NULL,
    details             TEXT            DEFAULT NULL,
    raw                 TEXT            DEFAULT NULL,
    link                TEXT            DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS job_try_fields_job_id ON job_try_fields(job_try_id);
CREATE INDEX IF NOT EXISTS job_try_fields_name   ON job_try_fields(name);

CREATE TABLE source_files (
    source_file_id  BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
    filename        VARCHAR(512)    NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_id   BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
    subname         VARCHAR(512)    NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE resource_types(
    resource_type_id    BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
    name                VARCHAR(512)    NOT NULL,

    UNIQUE(name)
);

CREATE TABLE resources (
    event_uuid          UUID            NOT NULL,

    resource_id         BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    resource_type_id    BIGINT          NOT NULL    REFERENCES resource_types(resource_type_id) ON DELETE CASCADE,
    run_id              BIGINT          NOT NULL    REFERENCES runs(run_id)                     ON DELETE CASCADE,
    host_id             BIGINT                      REFERENCES hosts(host_id)                   ON DELETE SET NULL,

    stamp               TIMESTAMP(6)    NOT NULL,
    resource_ord        INTEGER         NOT NULL,

    data                JSON            NOT NULL,

    UNIQUE(run_id, resource_ord)
);
CREATE INDEX IF NOT EXISTS res_data_runs         ON resources(run_id);
CREATE INDEX IF NOT EXISTS res_data_run_ords     ON resources(run_id, resource_ord);
CREATE INDEX IF NOT EXISTS res_data_res          ON resources(resource_type_id);
CREATE INDEX IF NOT EXISTS res_data_runs_and_res ON resources(run_id, resource_type_id);

CREATE TABLE coverage_manager (
    coverage_manager_id   BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    event_uuid              UUID        NOT NULL,

    coverage_id             BIGINT      NOT NULL        PRIMARY KEY AUTO_INCREMENT,

    job_try_id              BIGINT      DEFAULT NULL    REFERENCES job_tries(job_try_id)                   ON DELETE SET NULL,
    coverage_manager_id     BIGINT      DEFAULT NULL    REFERENCES coverage_manager(coverage_manager_id)   ON DELETE CASCADE,

    run_id                  BIGINT      NOT NULL        REFERENCES runs(run_id)                            ON DELETE CASCADE,
    test_file_id            BIGINT      NOT NULL        REFERENCES test_files(test_file_id)                ON DELETE CASCADE,
    source_file_id          BIGINT      NOT NULL        REFERENCES source_files(source_file_id)            ON DELETE CASCADE,
    source_sub_id           BIGINT      NOT NULL        REFERENCES source_subs(source_sub_id)              ON DELETE CASCADE,

    metadata                JSON        DEFAULT NULL,

    UNIQUE(run_id, job_try_id, test_file_id, source_file_id, source_sub_id)
);
CREATE INDEX IF NOT EXISTS coverage_from_source     ON coverage(source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX IF NOT EXISTS coverage_from_job        ON coverage(job_try_id);

CREATE TABLE reporting (
    reporting_id    BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,

    job_try_id      BIGINT          DEFAULT NULL    REFERENCES job_tries(job_try_id)       ON DELETE SET NULL,
    test_file_id    BIGINT          DEFAULT NULL    REFERENCES test_files(test_file_id)    ON DELETE CASCADE,

    project_id      BIGINT          NOT NULL        REFERENCES projects(project_id)        ON DELETE CASCADE,
    user_id         BIGINT          NOT NULL        REFERENCES users(user_id)              ON DELETE CASCADE,
    run_id          BIGINT          NOT NULL        REFERENCES runs(run_id)                ON DELETE CASCADE,

    job_try         SMALLINT        DEFAULT NULL,

    retry           SMALLINT        NOT NULL,
    abort           SMALLINT        NOT NULL,
    fail            SMALLINT        NOT NULL,
    pass            SMALLINT        NOT NULL,

    subtest         VARCHAR(512)    DEFAULT NULL,
    duration        NUMERIC(14,4)   NOT NULL
);
CREATE INDEX IF NOT EXISTS reporting_run  ON reporting(run_id);
CREATE INDEX IF NOT EXISTS reporting_user ON reporting(user_id);
CREATE INDEX IF NOT EXISTS reporting_a    ON reporting(project_id);
CREATE INDEX IF NOT EXISTS reporting_b    ON reporting(project_id, user_id);
CREATE INDEX IF NOT EXISTS reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, reporting_id);
