CREATE TABLE config(
    config_idx        BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    setting           VARCHAR(128)    NOT NULL,
    value             VARCHAR(256)    NOT NULL,
    UNIQUE(setting)
);

CREATE TABLE users (
    user_idx        BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    username        VARCHAR(64)     NOT NULL,
    pw_hash         VARCHAR(31)     DEFAULT NULL,
    pw_salt         VARCHAR(22)     DEFAULT NULL,
    realname        TEXT            DEFAULT NULL,
    role ENUM(
        'admin',    -- Can add users and set permissions
        'user'      -- Can manage reports for their projects
    ) NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE email (
    email_idx   BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_idx    BIGINT          NOT NULL,
    local       VARCHAR(128)    NOT NULL,
    domain      VARCHAR(128)    NOT NULL,
    verified    BOOL            NOT NULL DEFAULT FALSE,

    FOREIGN KEY (user_idx) REFERENCES users(user_idx) ON DELETE CASCADE,
    UNIQUE(local, domain)
);
CREATE INDEX email_user ON email(user_idx);

CREATE TABLE primary_email (
    user_idx    BIGINT  NOT NULL PRIMARY KEY,
    email_idx   BIGINT  NOT NULL,

    FOREIGN KEY (user_idx)  REFERENCES users(user_idx) ON DELETE CASCADE,
    FOREIGN KEY (email_idx) REFERENCES email(email_idx) ON DELETE CASCADE,

    unique(email_idx)
);

CREATE TABLE hosts (
    host_idx    BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    email_idx       BIGINT      NOT NULL PRIMARY KEY,
    evcode_id       BINARY(16)  NOT NULL,

    FOREIGN KEY (email_idx) REFERENCES email(email_idx) ON DELETE CASCADE
);

CREATE TABLE sessions (
    session_id      BINARY(16)  NOT NULL PRIMARY KEY,
    active          BOOL        DEFAULT TRUE
) ROW_FORMAT=COMPRESSED;

CREATE TABLE session_hosts (
    session_host_idx    BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_idx            BIGINT,
    session_id          BINARY(16)      NOT NULL,

    created             TIMESTAMP       NOT NULL DEFAULT now(),
    accessed            TIMESTAMP       NOT NULL DEFAULT now(),

    address             VARCHAR(128)    NOT NULL,
    agent               VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_idx)   REFERENCES users(user_idx) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE,

    UNIQUE(address, agent, session_id)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_idx     BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_idx        BIGINT          NOT NULL,
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(36)     NOT NULL,

    status ENUM( 'active', 'disabled', 'revoked') NOT NULL,

    FOREIGN KEY (user_idx) REFERENCES users(user_idx) ON DELETE CASCADE,

    UNIQUE(value)
);
CREATE INDEX api_key_user ON api_keys(user_idx);

CREATE TABLE log_files (
    log_file_idx    BIGINT  NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name            TEXT    NOT NULL,
    local_file      TEXT,
    data            LONGBLOB
) ROW_FORMAT=COMPRESSED;

CREATE TABLE projects (
    project_idx     BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(128)    NOT NULL,
    owner           BIGINT          DEFAULT NULL,

    FOREIGN KEY (owner) REFERENCES users(user_idx) ON DELETE SET NULL,
    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_idx  BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_idx     BIGINT      NOT NULL,
    user_idx        BIGINT      NOT NULL,
    updated         TIMESTAMP   NOT NULL DEFAULT now(),

    FOREIGN KEY (user_idx)    REFERENCES users(user_idx) ON DELETE CASCADE,
    FOREIGN KEY (project_idx) REFERENCES projects(project_idx) ON DELETE CASCADE,

    UNIQUE(project_idx, user_idx)
);

CREATE TABLE runs (
    run_idx         BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_idx        BIGINT          NOT NULL,
    project_idx     BIGINT          NOT NULL,
    log_file_idx    BIGINT          DEFAULT NULL,

    run_id          BINARY(16)      NOT NULL,

    status ENUM('pending', 'running', 'complete', 'broken', 'canceled') NOT NULL,

    worker_id       VARCHAR(36)     DEFAULT NULL,
    error           TEXT            DEFAULT NULL,

    pinned          BOOL            NOT NULL DEFAULT FALSE,
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    duration        VARCHAR(36)     DEFAULT NULL,

    mode            ENUM('qvfds', 'qvfd', 'qvf', 'summary', 'complete')
                                    DEFAULT 'qvfd'  NOT NULL,

    buffer          ENUM('none', 'diag', 'job', 'run')
                                    DEFAULT 'job'   NOT NULL,

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,

    FOREIGN KEY (user_idx)     REFERENCES users(user_idx) ON DELETE CASCADE,
    FOREIGN KEY (project_idx)  REFERENCES projects(project_idx) ON DELETE CASCADE,
    FOREIGN KEY (log_file_idx) REFERENCES log_files(log_file_idx) ON DELETE SET NULL,

    UNIQUE(run_id)
);
CREATE INDEX run_projects ON runs(project_idx);
CREATE INDEX run_status ON runs(status);
CREATE INDEX run_user ON runs(user_idx);

CREATE TABLE sweeps (
    sweep_idx       BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_idx         BIGINT          NOT NULL,
    name            VARCHAR(255)    NOT NULL,

    FOREIGN KEY (run_idx) REFERENCES runs(run_idx) ON DELETE CASCADE,

    UNIQUE(run_idx, name)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX sweep_runs ON sweeps(run_idx);

CREATE TABLE run_fields (
    run_field_idx   BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_field_id    BINARY(16)      NOT NULL,
    run_id          BINARY(16)      NOT NULL,
    name            VARCHAR(255)    NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE,

    UNIQUE(run_field_id)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX run_fields_run_id ON run_fields(run_id);
CREATE INDEX run_fields_name   ON run_fields(name);

CREATE TABLE run_parameters (
    run_parameters_idx  BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_id              BINARY(16)  NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    parameters          JSON        DEFAULT NULL,

    UNIQUE(run_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE test_files (
    test_file_idx   BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,

    filename        VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin
                                    NOT NULL,

    UNIQUE(filename)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE jobs (
    job_idx         BIGINT              NOT NULL AUTO_INCREMENT PRIMARY KEY,

    job_key         BINARY(16)          NOT NULL,
    job_id          BINARY(16)          NOT NULL,
    run_id          BINARY(16)          NOT NULL,

    test_file_idx   BIGINT              DEFAULT NULL,

    job_try         INT                 NOT NULL DEFAULT 0,
    status          ENUM('pending', 'running', 'complete', 'broken', 'canceled')
                                        NOT NULL DEFAULT 'pending',

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

    FOREIGN KEY (run_id)       REFERENCES runs(run_id) ON DELETE CASCADE,
    FOREIGN KEY (test_file_idx) REFERENCES test_files(test_file_idx) ON DELETE CASCADE,

    UNIQUE(job_key),
    UNIQUE(job_id, job_try)
);
CREATE INDEX job_runs ON jobs(run_id);
CREATE INDEX job_fail ON jobs(fail);
CREATE INDEX job_file ON jobs(test_file_idx);

CREATE TABLE job_parameters (
    job_parameters_idx  BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_key             BINARY(16)  NOT NULL REFERENCES jobs(job_key) ON DELETE CASCADE,
    parameters          JSON        DEFAULT NULL,

    UNIQUE(job_key)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE job_outputs (
    job_output_idx  BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_key         BINARY(16)  NOT NULL,

    stream          ENUM('STDOUT', 'STDERR')
                                NOT NULL,

    output          TEXT        NOT NULL,

    FOREIGN KEY (job_key)   REFERENCES jobs(job_key) ON DELETE CASCADE,

    UNIQUE(job_key, stream)
);

CREATE TABLE job_fields (
    job_field_idx   BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_field_id    BINARY(16)      NOT NULL,
    job_key         BINARY(16)      NOT NULL,
    name            VARCHAR(512)    NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (job_key) REFERENCES jobs(job_key) ON DELETE CASCADE,

    UNIQUE(job_field_id)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX job_fields_job_key ON job_fields(job_key);
CREATE INDEX job_fields_name    ON job_fields(name);

CREATE TABLE events (
    event_idx   BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    event_id    BINARY(16)  NOT NULL,

    job_key     BINARY(16)  NOT NULL,

    is_subtest  BOOL        NOT NULL,
    is_diag     BOOL        NOT NULL,
    is_harness  BOOL        NOT NULL,
    is_time     BOOL        NOT NULL,
    is_assert   BOOL        NOT NULL,

    causes_fail BOOL        NOT NULL,

    has_binary  BOOL        NOT NULL,
    has_facets  BOOL        NOT NULL,
    has_orphan  BOOL        NOT NULL,

    stamp       TIMESTAMP               DEFAULT NULL,

    parent_id   BINARY(16)              DEFAULT NULL,
    trace_id    VARCHAR(36)             DEFAULT NULL,
    nested      INT         NOT NULL    DEFAULT 0,

    FOREIGN KEY (job_key) REFERENCES jobs(job_key) ON DELETE CASCADE,
    -- FOREIGN KEY (parent_id) REFERENCES events(event_id),

    UNIQUE(event_id)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX event_job_ts ON events(job_key, stamp);
CREATE INDEX event_job_st ON events(job_key, is_subtest);
CREATE INDEX event_trace  ON events(trace_id);
CREATE INDEX event_parent ON events(parent_id);

CREATE TABLE renders (
    event_id    BINARY(16)  NOT NULL PRIMARY KEY,
    data        JSON        DEFAULT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,

    UNIQUE(event_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE facets (
    event_id    BINARY(16)  NOT NULL PRIMARY KEY,
    data        JSON        DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,

    UNIQUE(event_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE orphans (
    event_id    BINARY(16)  NOT NULL PRIMARY KEY,
    data        JSON        DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,

    UNIQUE(event_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE binaries (
    binary_idx      BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    event_id        BINARY(16)      NOT NULL,
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            LONGBLOB        NOT NULL,

    FOREIGN KEY (event_id)  REFERENCES events(event_id) ON DELETE CASCADE
) ROW_FORMAT=COMPRESSED;
CREATE INDEX binaries_event ON binaries(event_id);

CREATE TABLE source_files (
    source_file_idx BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,

    filename        VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin
                                    NOT NULL,

    UNIQUE(filename)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE source_subs (
    source_sub_idx  BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,

    subname         VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin
                                    NOT NULL,

    UNIQUE(subname)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE coverage_manager (
    coverage_manager_idx  BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,

    package               VARCHAR(256)  CHARACTER SET utf8 COLLATE utf8_bin
                                        NOT NULL,

    UNIQUE(package)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE coverage (
    coverage_idx            BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,

    run_id                  BINARY(16)  NOT NULL,
    job_key                 BINARY(16)  DEFAULT NULL,

    test_file_idx           BIGINT      NOT NULL,
    source_file_idx         BIGINT      NOT NULL,
    source_sub_idx          BIGINT      NOT NULL,
    coverage_manager_idx    BIGINT      DEFAULT NULL,

    metadata                JSON        DEFAULT NULL,

    FOREIGN KEY (run_id)               REFERENCES runs(run_id) ON DELETE CASCADE,
    FOREIGN KEY (job_key)              REFERENCES jobs(job_key) ON DELETE CASCADE,
    FOREIGN KEY (test_file_idx)        REFERENCES test_files(test_file_idx) ON DELETE CASCADE,
    FOREIGN KEY (source_file_idx)      REFERENCES source_files(source_file_idx) ON DELETE CASCADE,
    FOREIGN KEY (source_sub_idx)       REFERENCES source_subs(source_sub_idx) ON DELETE CASCADE,
    FOREIGN KEY (coverage_manager_idx) REFERENCES coverage_manager(coverage_manager_idx) ON DELETE CASCADE,

    UNIQUE(run_id, job_key, test_file_idx, source_file_idx, source_sub_idx)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX coverage_from_source     ON coverage(source_file_idx, source_sub_idx);
CREATE INDEX coverage_from_run_source ON coverage(run_id, source_file_idx, source_sub_idx);
CREATE INDEX coverage_from_job        ON coverage(job_key);

CREATE TABLE reporting (
    reporting_idx   BIGINT              NOT NULL AUTO_INCREMENT PRIMARY KEY,

    project_idx     BIGINT              NOT NULL,
    user_idx        BIGINT              NOT NULL,
    run_id          BINARY(16)          NOT NULL,

    test_file_idx   BIGINT              DEFAULT NULL,
    job_key         BINARY(16)          DEFAULT NULL,
    event_id        BINARY(16)          DEFAULT NULL,

    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT    NOT NULL DEFAULT 0,
    pass            SMALLINT    NOT NULL DEFAULT 0,
    retry           SMALLINT    NOT NULL DEFAULT 0,
    abort           SMALLINT    NOT NULL DEFAULT 0,

    FOREIGN KEY (run_id)        REFERENCES runs(run_id) ON DELETE CASCADE,
    FOREIGN KEY (job_key)       REFERENCES jobs(job_key) ON DELETE CASCADE,
    FOREIGN KEY (event_id)      REFERENCES events(event_id) ON DELETE CASCADE,
    FOREIGN KEY (project_idx)   REFERENCES projects(project_idx) ON DELETE CASCADE,
    FOREIGN KEY (user_idx)      REFERENCES users(user_idx) ON DELETE CASCADE,
    FOREIGN KEY (test_file_idx) REFERENCES test_files(test_file_idx) ON DELETE CASCADE
);
CREATE INDEX reporting_user ON reporting(user_idx);
CREATE INDEX reporting_run  ON reporting(run_id);
CREATE INDEX reporting_a    ON reporting(project_idx);
CREATE INDEX reporting_b    ON reporting(project_idx, user_idx);
CREATE INDEX reporting_e    ON reporting(project_idx, test_file_idx, subtest, user_idx, reporting_idx);

CREATE TABLE resource_batch (
    resource_batch_idx  BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_id              BINARY(16)      NOT NULL,
    host_idx            BIGINT          NOT NULL,
    stamp               TIMESTAMP(4)    NOT NULL,

    FOREIGN KEY (run_id)   REFERENCES runs(run_id) ON DELETE CASCADE,
    FOREIGN KEY (host_idx) REFERENCES hosts(host_idx) ON DELETE CASCADE
) ROW_FORMAT=COMPRESSED;
CREATE INDEX resource_batch_run ON resource_batch(run_id);

CREATE TABLE resources (
    resource_idx        BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    resource_batch_idx  BIGINT          NOT NULL,
    module              VARCHAR(512)    NOT NULL,
    data                JSON            NOT NULL,

    FOREIGN KEY (resource_batch_idx) REFERENCES resource_batch(resource_batch_idx) ON DELETE CASCADE
) ROW_FORMAT=COMPRESSED;
CREATE INDEX resources_batch_idx ON resources(resource_batch_idx);
