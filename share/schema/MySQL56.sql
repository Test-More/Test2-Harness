CREATE TABLE users (
    user_id         CHAR(36)        NOT NULL PRIMARY KEY,
    username        VARCHAR(64)     NOT NULL,
    pw_hash         VARCHAR(31)     DEFAULT NULL,
    pw_salt         VARCHAR(22)     DEFAULT NULL,
    realname        VARCHAR(64)     DEFAULT NULL,
    role ENUM(
        'admin',    -- Can add users and set permissions
        'user'      -- Can manage reports for their projects
    ) NOT NULL,

    UNIQUE(username)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE email (
    email_id        CHAR(36)        NOT NULL PRIMARY KEY,
    user_id         CHAR(36)        NOT NULL,
    local           VARCHAR(128)    NOT NULL,
    domain          VARCHAR(128)    NOT NULL,
    verified        BOOL            NOT NULL DEFAULT FALSE,

    FOREIGN KEY (user_id) REFERENCES users(user_id),
    UNIQUE(local, domain)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE primary_email (
    user_id         CHAR(36)        NOT NULL PRIMARY KEY,
    email_id        CHAR(36)        NOT NULL,

    FOREIGN KEY (user_id)  REFERENCES users(user_id),
    FOREIGN KEY (email_id) REFERENCES email(email_id),
    unique(email_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE hosts (
    host_id     CHAR(36)        NOT NULL PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE email_verification_codes (
    evcode_id       CHAR(36)        NOT NULL PRIMARY KEY,
    email_id        CHAR(36)        NOT NULL,

    FOREIGN KEY (email_id) REFERENCES email(email_id),

    unique(email_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE sessions (
    session_id      CHAR(36) NOT NULL PRIMARY KEY,
    active          BOOL     DEFAULT TRUE
) ROW_FORMAT=COMPRESSED;

CREATE TABLE session_hosts (
    session_host_id     CHAR(36)    NOT NULL PRIMARY KEY,
    session_id          CHAR(36)    NOT NULL,
    user_id             CHAR(36),

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             VARCHAR(128)    NOT NULL,
    agent               VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_id)    REFERENCES users(user_id),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),

    UNIQUE(session_id, address, agent)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_id      CHAR(36)        NOT NULL PRIMARY KEY,
    user_id         CHAR(36)        NOT NULL,
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(36)     NOT NULL,

    status ENUM( 'active', 'disabled', 'revoked') NOT NULL,

    FOREIGN KEY (user_id) REFERENCES users(user_id),

    UNIQUE(value)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     CHAR(36)        NOT NULL PRIMARY KEY,
    name            TEXT            NOT NULL,

    local_file      TEXT,
    data            LONGBLOB
) ROW_FORMAT=COMPRESSED;

CREATE TABLE projects (
    project_id      CHAR(36)        NOT NULL PRIMARY KEY,
    name            VARCHAR(128)    NOT NULL,
    owner           CHAR(36)        DEFAULT NULL,

    FOREIGN KEY (owner) REFERENCES users(user_id),
    UNIQUE(name)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE permissions (
    permission_id   CHAR(36)        NOT NULL PRIMARY KEY,
    project_id      CHAR(36)        NOT NULL,
    user_id         CHAR(36)        NOT NULL,
    updated         TIMESTAMP       NOT NULL DEFAULT now(),

    cpan_batch      BIGINT          DEFAULT NULL,

    FOREIGN KEY (user_id)    REFERENCES users(user_id),
    FOREIGN KEY (project_id) REFERENCES projects(project_id),
    UNIQUE(project_id, user_id)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE runs (
    run_id          CHAR(36)        NOT NULL PRIMARY KEY,
    user_id         CHAR(36)        NOT NULL,

    run_ord         BIGINT          NOT NULL AUTO_INCREMENT,

    status ENUM('pending', 'running', 'complete', 'broken', 'canceled') NOT NULL,
    worker_id       TEXT            DEFAULT NULL,

    error           TEXT            DEFAULT NULL,
    project_id      CHAR(36)        NOT NULL,

    pinned          BOOL            NOT NULL DEFAULT FALSE,
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    duration        TEXT            DEFAULT NULL,
    log_file_id     CHAR(36)        DEFAULT NULL,

    mode ENUM('qvfds', 'qvfd', 'qvf', 'summary', 'complete') NOT NULL,
    buffer ENUM('none', 'diag', 'job', 'run') DEFAULT 'job' NOT NULL,

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,
    parameters      LONGTEXT        DEFAULT NULL,

    FOREIGN KEY (user_id)     REFERENCES users(user_id),
    FOREIGN KEY (project_id)  REFERENCES projects(project_id),
    FOREIGN KEY (log_file_id) REFERENCES log_files(log_file_id),
    UNIQUE(run_ord)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX run_projects ON runs(project_id);
CREATE INDEX run_status ON runs(status);
CREATE INDEX run_user ON runs(user_id);

CREATE TABLE sweeps (
    sweep_id        CHAR(36)        NOT NULL PRIMARY KEY,
    run_id          CHAR(36)        NOT NULL,
    name            VARCHAR(255)    NOT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id),

    UNIQUE(run_id, name)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX sweep_runs ON sweeps(run_id);

CREATE TABLE run_fields (
    run_field_id    CHAR(36)        NOT NULL PRIMARY KEY,
    run_id          CHAR(36)        NOT NULL,
    name            VARCHAR(255)    NOT NULL,
    data            LONGTEXT        DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id),

    UNIQUE(run_id, name)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE test_files (
    test_file_id    CHAR(36)                                            NOT NULL PRIMARY KEY,
    filename        VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin NOT NULL,

    UNIQUE(filename)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE jobs (
    job_key         CHAR(36)    NOT NULL PRIMARY KEY,

    job_id          CHAR(36)    NOT NULL,
    job_try         INT         NOT NULL DEFAULT 0,
    job_ord         BIGINT      NOT NULL,
    run_id          CHAR(36)    NOT NULL,

    is_harness_out  BOOL        NOT NULL DEFAULT 0,

    status ENUM('pending', 'running', 'complete', 'broken', 'canceled') NOT NULL,

    parameters      LONGTEXT        DEFAULT NULL,
    fields          LONGTEXT        DEFAULT NULL,

    test_file_id    CHAR(36)    DEFAULT NULL,

    -- Summaries
    name            TEXT            DEFAULT NULL,
    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    exit_code       INT             DEFAULT NULL,
    launch          TIMESTAMP,
    start           TIMESTAMP,
    ended           TIMESTAMP,

    duration        DOUBLE PRECISION    DEFAULT NULL,

    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    -- Coverage
    coverage_manager    TEXT        DEFAULT NULL,

    -- Output data
    stdout          LONGTEXT        DEFAULT NULL,
    stderr          LONGTEXT        DEFAULT NULL,

    FOREIGN KEY (run_id)       REFERENCES runs(run_id),
    FOREIGN KEY (test_file_id) REFERENCES test_files(test_file_id),

    UNIQUE(job_id, job_try)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX job_runs ON jobs(run_id);
CREATE INDEX job_fail ON jobs(fail);
CREATE INDEX job_file ON jobs(test_file_id);

CREATE TABLE job_fields (
    job_field_id    CHAR(36)        NOT NULL PRIMARY KEY,
    job_key         CHAR(36)        NOT NULL,
    name            VARCHAR(255)    NOT NULL,
    data            LONGTEXT        DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (job_key) REFERENCES jobs(job_key),

    UNIQUE(job_key, name)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE events (
    event_id        CHAR(36)    NOT NULL PRIMARY KEY,

    job_key         CHAR(36)    NOT NULL,

    event_ord       BIGINT      NOT NULL,
    insert_ord      BIGINT      NOT NULL AUTO_INCREMENT,

    has_binary      BOOL        NOT NULL DEFAULT FALSE,
    is_subtest      BOOL        NOT NULL DEFAULT FALSE,
    is_diag         BOOL        NOT NULL DEFAULT FALSE,
    is_harness      BOOL        NOT NULL DEFAULT FALSE,
    is_time         BOOL        NOT NULL DEFAULT FALSE,

    stamp           TIMESTAMP,

    parent_id       CHAR(36)    DEFAULT NULL,
    trace_id        CHAR(36)    DEFAULT NULL,
    nested          INT         DEFAULT 0,

    facets          LONGTEXT    DEFAULT NULL,
    facets_line     BIGINT      DEFAULT NULL,

    orphan          LONGTEXT    DEFAULT NULL,
    orphan_line     BIGINT      DEFAULT NULL,

    UNIQUE(insert_ord, job_key),
    FOREIGN KEY (job_key) REFERENCES jobs(job_key)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX event_job    ON events(job_key);
CREATE INDEX event_trace  ON events(trace_id);
CREATE INDEX event_parent ON events(parent_id);
CREATE INDEX is_subtest   ON events(is_subtest);

CREATE TABLE binaries (
    binary_id       CHAR(36)        NOT NULL PRIMARY KEY,
    event_id        CHAR(36)        NOT NULL,
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            LONGBLOB        NOT NULL,

    FOREIGN KEY (event_id)        REFERENCES events(event_id)
);

CREATE TABLE source_files (
    source_file_id  CHAR(36)                                            NOT NULL PRIMARY KEY,
    filename        VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin NOT NULL,

    UNIQUE(filename)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE source_subs (
    source_sub_id   CHAR(36)                                            NOT NULL PRIMARY KEY,
    subname         VARCHAR(512)    CHARACTER SET utf8 COLLATE utf8_bin NOT NULL,

    UNIQUE(subname)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE coverage_manager (
    coverage_manager_id   CHAR(36)                                          NOT NULL PRIMARY KEY,
    package               VARCHAR(256)  CHARACTER SET utf8 COLLATE utf8_bin NOT NULL,

    UNIQUE(package)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE coverage (
    coverage_id     CHAR(36)    NOT NULL PRIMARY KEY,

    run_id              CHAR(36)    NOT NULL,
    test_file_id        CHAR(36)    NOT NULL,
    source_file_id      CHAR(36)    NOT NULL,
    source_sub_id       CHAR(36)    NOT NULL,
    coverage_manager_id CHAR(36)    DEFAULT NULL,
    job_key             CHAR(36)    DEFAULT NULL,

    metadata    LONGTEXT    DEFAULT NULL,

    FOREIGN KEY (run_id)              REFERENCES runs(run_id),
    FOREIGN KEY (test_file_id)        REFERENCES test_files(test_file_id),
    FOREIGN KEY (source_file_id)      REFERENCES source_files(source_file_id),
    FOREIGN KEY (source_sub_id)       REFERENCES source_subs(source_sub_id),
    FOREIGN KEY (coverage_manager_id) REFERENCES coverage_manager(coverage_manager_id),
    FOREIGN KEY (job_key)             REFERENCES jobs(job_key),

    UNIQUE(run_id, test_file_id, source_file_id, source_sub_id)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX coverage_from_source ON coverage(source_file_id, source_sub_id);
CREATE INDEX coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX coverage_from_job ON coverage(job_key);

CREATE TABLE reporting (
    reporting_id    CHAR(36)            NOT NULL PRIMARY KEY,
    run_ord         BIGINT              NOT NULL,
    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT    NOT NULL DEFAULT 0,
    pass            SMALLINT    NOT NULL DEFAULT 0,
    retry           SMALLINT    NOT NULL DEFAULT 0,
    abort           SMALLINT    NOT NULL DEFAULT 0,

    project_id      CHAR(36)    NOT NULL,
    run_id          CHAR(36)    NOT NULL,
    user_id         CHAR(36)    NOT NULL,
    job_key         CHAR(36)    DEFAULT NULL,
    test_file_id    CHAR(36)    DEFAULT NULL,
    event_id        CHAR(36)    DEFAULT NULL,

    FOREIGN KEY (project_id)      REFERENCES projects(project_id),
    FOREIGN KEY (run_id)          REFERENCES runs(run_id),
    FOREIGN KEY (user_id)         REFERENCES users(user_id),
    FOREIGN KEY (job_key)         REFERENCES jobs(job_key),
    FOREIGN KEY (test_file_id)    REFERENCES test_files(test_file_id),
    FOREIGN KEY (event_id)        REFERENCES events(event_id)
);
CREATE INDEX reporting_user ON reporting(user_id);
CREATE INDEX reporting_a    ON reporting(project_id);
CREATE INDEX reporting_b    ON reporting(project_id, user_id);
CREATE INDEX reporting_c    ON reporting(project_id, test_file_id, subtest);
CREATE INDEX reporting_d    ON reporting(project_id, test_file_id, subtest, user_id);
CREATE INDEX reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, run_ord);

CREATE TABLE resources (
    resource_id     CHAR(36)        NOT NULL PRIMARY KEY,
    run_id          CHAR(36)        DEFAULT NULL,

    module          VARCHAR(512)    NOT NULL,
    stamp           TIMESTAMP(4)    NOT NULL,
    data            LONGTEXT        NOT NULL,

    FOREIGN KEY (run_id)            REFERENCES runs(run_id)
);
