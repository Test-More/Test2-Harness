CREATE TABLE versions(
    version     NUMERIC(10,6)   NOT NULL,
    version_id  INT             NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    updated     DATETIME        NOT NULL    DEFAULT now(),

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
    user_id     BIGINT          NOT NULL,
    verified    BOOL            NOT NULL DEFAULT FALSE,

    local       VARCHAR(128)    NOT NULL,
    domain      VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,

    UNIQUE(local, domain)
);
CREATE INDEX email_user ON email(user_id);

CREATE TABLE primary_email (
    user_id     BIGINT  NOT NULL PRIMARY KEY,
    email_id    BIGINT  NOT NULL,

    FOREIGN KEY (user_id)   REFERENCES users(user_id)  ON DELETE CASCADE,
    FOREIGN KEY (email_id)  REFERENCES email(email_id) ON DELETE CASCADE,

    unique(email_id)
);

CREATE TABLE hosts (
    host_id     BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    evcode      BINARY(16)  NOT NULL,
    email_id    BIGINT      NOT NULL PRIMARY KEY,

    FOREIGN KEY (email_id) REFERENCES email(email_id) ON DELETE CASCADE
);

CREATE TABLE sessions (
    session_uuid    BINARY(16)  NOT NULL,
    session_id      BIGINT      NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    active          BOOL                    DEFAULT TRUE,

    UNIQUE(session_uuid)
);

CREATE TABLE session_hosts (
    session_host_id     BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    session_id          BIGINT          NOT NULL,
    user_id             BIGINT,

    created             DATETIME        NOT NULL DEFAULT now(),
    accessed            DATETIME        NOT NULL DEFAULT now(),

    address             VARCHAR(128)    NOT NULL,
    agent               VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_id)       REFERENCES users(user_id)       ON DELETE CASCADE,
    FOREIGN KEY (session_id)    REFERENCES sessions(session_id) ON DELETE CASCADE,

    UNIQUE(address, agent, session_id)
);
CREATE INDEX session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    value       BINARY(16)      NOT NULL,
    api_key_id  BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    user_id     BIGINT          NOT NULL,

    status      ENUM( 'active', 'disabled', 'revoked')
                                NOT NULL DEFAULT 'active',

    name        VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_id)   REFERENCES users(user_id) ON DELETE CASCADE,

    UNIQUE(value)
);
CREATE INDEX api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     BIGINT      NOT NULL PRIMARY KEY AUTO_INCREMENT,
    name            TEXT        NOT NULL,
    local_file      TEXT,
    data            LONGBLOB
);

CREATE TABLE projects (
    project_id      BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    owner           BIGINT          DEFAULT NULL,
    name            VARCHAR(128)    NOT NULL,

    FOREIGN KEY (owner) REFERENCES users(user_id) ON DELETE SET NULL,

    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   BIGINT      NOT NULL PRIMARY KEY AUTO_INCREMENT,
    project_id      BIGINT      NOT NULL,
    user_id         BIGINT      NOT NULL,
    updated         DATETIME    NOT NULL DEFAULT now(),

    FOREIGN KEY (project_id)    REFERENCES projects(project_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id)       REFERENCES users(user_id)       ON DELETE CASCADE,

    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_uuid        BINARY(16)      NOT NULL,

    run_id          BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    user_id         BIGINT          NOT NULL,
    project_id      BIGINT          NOT NULL,
    log_file_id     BIGINT          DEFAULT NULL,

    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    to_retry        INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency_j   INTEGER         DEFAULT NULL,
    concurrency_x   INTEGER         DEFAULT NULL,
    added           DATETIME        NOT NULL        DEFAULT now(),

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

    FOREIGN KEY (user_id)       REFERENCES users(user_id)          ON DELETE CASCADE,
    FOREIGN KEY (project_id)    REFERENCES projects(project_id)    ON DELETE CASCADE,
    FOREIGN KEY (log_file_id)   REFERENCES log_files(log_file_id)  ON DELETE SET NULL,

    UNIQUE(run_uuid)
);
CREATE INDEX run_projects ON runs(project_id);
CREATE INDEX run_status   ON runs(status);
CREATE INDEX run_user     ON runs(user_id);
CREATE INDEX run_canon    ON runs(run_id, canon);

CREATE TABLE sweeps (
    sweep_id        BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT          NOT NULL,
    name            VARCHAR(64)     NOT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE,

    UNIQUE(run_id, name)
);
CREATE INDEX sweep_runs ON sweeps(run_id);

CREATE TABLE test_files (
    test_file_id    BIGINT          NOT NULL PRIMARY KEY AUTO_INCREMENT,
    filename        VARCHAR(255)    NOT NULL,

    UNIQUE(filename)
);

INSERT INTO test_files(filename) VALUES('HARNESS INTERNAL LOG');

CREATE TABLE jobs (
    job_uuid        BINARY(16)  NOT NULL,

    job_id          BIGINT      NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT      NOT NULL,
    test_file_id    BIGINT      NOT NULL,

    is_harness_out  BOOL        NOT NULL,
    failed          BOOL        NOT NULL,
    passed          BOOL        DEFAULT NULL,

    FOREIGN KEY (run_id)        REFERENCES runs(run_id)             ON DELETE CASCADE,
    FOREIGN KEY (test_file_id)  REFERENCES test_files(test_file_id) ON DELETE CASCADE,

    UNIQUE(job_uuid)
);
CREATE INDEX job_runs ON jobs(run_id);
CREATE INDEX job_file ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_uuid    BINARY(16)      NOT NULL,
    job_try_id      BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    job_id          BIGINT          NOT NULL,
    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    exit_code       INTEGER         DEFAULT NULL,
    launch          DATETIME        DEFAULT NULL,
    start           DATETIME        DEFAULT NULL,
    ended           DATETIME        DEFAULT NULL,


    status          ENUM('pending', 'running', 'complete', 'broken', 'canceled')
                                    NOT NULL    DEFAULT 'pending',

    job_try_ord     SMALLINT        NOT NULL,

    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    duration        NUMERIC(14,4)   DEFAULT NULL,

    parameters      JSON            DEFAULT NULL,
    stdout          TEXT            DEFAULT NULL,
    stderr          TEXT            DEFAULT NULL,

    FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE,

    UNIQUE(job_try_id, job_try_ord)
);
CREATE INDEX job_try_fail     ON job_tries(fail);
CREATE INDEX job_try_job_fail ON job_tries(job_id, fail);

CREATE TABLE events (
    event_uuid      BINARY(16)  NOT NULL,
    trace_uuid      BINARY(16)  DEFAULT NULL,
    parent_uuid     BINARY(16)  DEFAULT NULL,

    event_id        BIGINT      NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    job_try_id      BIGINT      NOT NULL,
    parent_id       BIGINT      DEFAULT NULL,

    event_idx       INTEGER     NOT NULL, -- Line number from log, or event number from stream
    event_sdx       INTEGER     NOT NULL, -- Event sequence number from the line (IE parent + subtest events)
    stamp           DATETIME    DEFAULT NULL,

    nested          SMALLINT    NOT NULL,

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

    FOREIGN KEY (parent_uuid)   REFERENCES events(event_uuid),
    FOREIGN KEY (job_try_id)    REFERENCES job_tries(job_try_id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id)     REFERENCES events(event_id)      ON DELETE CASCADE,

    UNIQUE(job_try_id, event_idx, event_sdx),
    UNIQUE(event_uuid)
);
CREATE INDEX event_parent ON events(parent_id);
CREATE INDEX event_job_ts ON events(job_try_id, stamp);
CREATE INDEX event_job_st ON events(job_try_id, is_subtest);

CREATE TABLE binaries (
    event_uuid      BINARY(16)      NOT NULL,

    binary_id       BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,
    event_id        BIGINT          DEFAULT NULL,

    is_image        BOOL            NOT NULL DEFAULT FALSE,

    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    data            LONGBLOB        NOT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE
);
CREATE INDEX binaries_event ON binaries(event_id);

CREATE TABLE run_fields (
    event_uuid      BINARY(16)      NOT NULL,

    run_field_id    BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    run_id          BIGINT          NOT NULL,

    name            VARCHAR(64)     NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
);
CREATE INDEX run_fields_run_id ON run_fields(run_id);
CREATE INDEX run_fields_name   ON run_fields(name);

CREATE TABLE job_try_fields (
    event_uuid          BINARY(16)      NOT NULL,

    job_try_field_id    BIGINT          NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    job_try_id          BIGINT          NOT NULL,

    name                VARCHAR(64)     NOT NULL,
    data                JSON            DEFAULT NULL,
    details             TEXT            DEFAULT NULL,
    raw                 TEXT            DEFAULT NULL,
    link                TEXT            DEFAULT NULL,

    FOREIGN KEY (job_try_id) REFERENCES job_tries(job_try_id) ON DELETE CASCADE
);
CREATE INDEX job_try_fields_job_id ON job_try_fields(job_try_id);
CREATE INDEX job_try_fields_name   ON job_try_fields(name);

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
    event_uuid          BINARY(16)  NOT NULL,

    resource_id         BIGINT      NOT NULL    PRIMARY KEY AUTO_INCREMENT,
    resource_type_id    BIGINT      NOT NULL,
    run_id              BIGINT      NOT NULL,
    host_id             BIGINT,

    stamp               DATETIME    NOT NULL,
    resource_ord        INTEGER     NOT NULL,

    data                JSON        NOT NULL,

    FOREIGN KEY (resource_type_id)  REFERENCES resource_types(resource_type_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id)            REFERENCES runs(run_id)                     ON DELETE CASCADE,
    FOREIGN KEY (host_id)           REFERENCES hosts(host_id)                   ON DELETE SET NULL,

    UNIQUE(run_id, resource_ord)
);
CREATE INDEX res_data_runs         ON resources(run_id);
CREATE INDEX res_data_run_ords     ON resources(run_id, resource_ord);
CREATE INDEX res_data_res          ON resources(resource_type_id);
CREATE INDEX res_data_runs_and_res ON resources(run_id, resource_type_id);

CREATE TABLE coverage_manager (
    coverage_manager_id   BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
    package               VARCHAR(256)  NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    event_uuid              BINARY(16)  NOT NULL,

    coverage_id             BIGINT      NOT NULL        PRIMARY KEY AUTO_INCREMENT,

    job_try_id              BIGINT      DEFAULT NULL,
    coverage_manager_id     BIGINT      DEFAULT NULL,

    run_id                  BIGINT      NOT NULL,
    test_file_id            BIGINT      NOT NULL,
    source_file_id          BIGINT      NOT NULL,
    source_sub_id           BIGINT      NOT NULL,

    metadata                JSON        DEFAULT NULL,

    FOREIGN KEY (job_try_id)            REFERENCES job_tries(job_try_id)                   ON DELETE SET NULL,
    FOREIGN KEY (coverage_manager_id)   REFERENCES coverage_manager(coverage_manager_id)   ON DELETE CASCADE,
    FOREIGN KEY (run_id)                REFERENCES runs(run_id)                            ON DELETE CASCADE,
    FOREIGN KEY (test_file_id)          REFERENCES test_files(test_file_id)                ON DELETE CASCADE,
    FOREIGN KEY (source_file_id)        REFERENCES source_files(source_file_id)            ON DELETE CASCADE,
    FOREIGN KEY (source_sub_id)         REFERENCES source_subs(source_sub_id)              ON DELETE CASCADE,

    UNIQUE(run_id, job_try_id, test_file_id, source_file_id, source_sub_id)
);
CREATE INDEX coverage_from_source     ON coverage(source_file_id, source_sub_id);
CREATE INDEX coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX coverage_from_job        ON coverage(job_try_id);

CREATE TABLE reporting (
    reporting_id    BIGINT          NOT NULL        PRIMARY KEY AUTO_INCREMENT,

    job_try_id      BIGINT          DEFAULT NULL,
    test_file_id    BIGINT          DEFAULT NULL,

    project_id      BIGINT          NOT NULL,
    user_id         BIGINT          NOT NULL,
    run_id          BIGINT          NOT NULL,

    job_try         SMALLINT        DEFAULT NULL,

    retry           SMALLINT        NOT NULL,
    abort           SMALLINT        NOT NULL,
    fail            SMALLINT        NOT NULL,
    pass            SMALLINT        NOT NULL,

    subtest         VARCHAR(512)    DEFAULT NULL,
    duration        NUMERIC(14,4)   NOT NULL,

    FOREIGN KEY (job_try_id)    REFERENCES job_tries(job_try_id)       ON DELETE SET NULL,
    FOREIGN KEY (test_file_id)  REFERENCES test_files(test_file_id)    ON DELETE CASCADE,
    FOREIGN KEY (project_id)    REFERENCES projects(project_id)        ON DELETE CASCADE,
    FOREIGN KEY (user_id)       REFERENCES users(user_id)              ON DELETE CASCADE,
    FOREIGN KEY (run_id)        REFERENCES runs(run_id)                ON DELETE CASCADE
);
CREATE INDEX reporting_run  ON reporting(run_id);
CREATE INDEX reporting_user ON reporting(user_id);
CREATE INDEX reporting_a    ON reporting(project_id);
CREATE INDEX reporting_b    ON reporting(project_id, user_id);
CREATE INDEX reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, reporting_id);


