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

    UNIQUE(name)
) ROW_FORMAT=COMPRESSED;

CREATE TABLE permissions (
    permission_id   CHAR(36)        NOT NULL PRIMARY KEY,
    project_id      CHAR(36)        NOT NULL REFERENCES projects(project_id),
    user_id         CHAR(36)        NOT NULL REFERENCES users(user_id),
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

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT now(),
    duration        TEXT            DEFAULT NULL,
    log_file_id     CHAR(36)        DEFAULT NULL,

    mode ENUM('qvfd', 'qvf', 'summary', 'complete') NOT NULL,
    buffer ENUM('none', 'diag', 'job', 'run') DEFAULT 'job' NOT NULL,

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,
    fields          LONGTEXT        DEFAULT NULL,
    parameters      LONGTEXT        DEFAULT NULL,
    coverage        LONGTEXT        DEFAULT NULL,

    FOREIGN KEY (user_id)     REFERENCES users(user_id),
    FOREIGN KEY (project_id)  REFERENCES projects(project_id),
    FOREIGN KEY (log_file_id) REFERENCES log_files(log_file_id),
    UNIQUE(run_ord)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX run_projects ON runs(project_id);
CREATE INDEX run_status ON runs(status);
CREATE INDEX run_user ON runs(user_id);

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

    -- Summaries
    name            TEXT            DEFAULT NULL,
    file            VARCHAR(512)    DEFAULT NULL,
    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    exit_code       INT             DEFAULT NULL,
    launch          TIMESTAMP,
    start           TIMESTAMP,
    ended           TIMESTAMP,

    duration        DOUBLE PRECISION    DEFAULT NULL,

    pass_count      BIGINT          DEFAULT NULL,
    fail_count      BIGINT          DEFAULT NULL,

    -- Output data
    stdout          LONGTEXT        DEFAULT NULL,
    stderr          LONGTEXT        DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id),

    UNIQUE(job_id, job_try)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX job_look ON jobs(job_id, job_try);
CREATE INDEX job_runs ON jobs(run_id);
CREATE INDEX job_fail ON jobs(fail);
CREATE INDEX job_file ON jobs(file);

CREATE TABLE events (
    event_id        CHAR(36)    NOT NULL PRIMARY KEY,

    job_key         CHAR(36)    NOT NULL REFERENCES jobs(job_key),

    event_ord       BIGINT      NOT NULL,
    insert_ord      BIGINT      NOT NULL AUTO_INCREMENT,

    is_diag         BOOL        NOT NULL DEFAULT FALSE,
    is_harness      BOOL        NOT NULL DEFAULT FALSE,
    is_time         BOOL        NOT NULL DEFAULT FALSE,

    stamp           TIMESTAMP,

    parent_id       CHAR(36)    DEFAULT NULL,
    trace_id        CHAR(36)    DEFAULT NULL,
    nested          INT         DEFAULT 0,

    facets          LONGTEXT  DEFAULT NULL,
    facets_line     BIGINT      DEFAULT NULL,

    orphan          LONGTEXT  DEFAULT NULL,
    orphan_line     BIGINT      DEFAULT NULL,

    UNIQUE(insert_ord),
    FOREIGN KEY (job_key) REFERENCES jobs(job_key)
) ROW_FORMAT=COMPRESSED;
CREATE INDEX event_job    ON events(job_key);
CREATE INDEX event_trace  ON events(trace_id);
CREATE INDEX event_parent ON events(parent_id);
