CREATE TABLE config(
    config_id         UUID            NOT NULL PRIMARY KEY,
    setting           VARCHAR(128)    NOT NULL,
    value             VARCHAR(256)    NOT NULL,
    UNIQUE(setting)
);

CREATE TABLE users (
    user_id         UUID            NOT NULL PRIMARY KEY,
    username        VARCHAR(64)     NOT NULL,
    pw_hash         VARCHAR(31)     DEFAULT NULL,
    pw_salt         VARCHAR(22)     DEFAULT NULL,
    realname        VARCHAR(64)     DEFAULT NULL,
    role TEXT CHECK(role IN (
        'admin',    -- Can add users and set permissions
        'user'      -- Can manage reports for their projects
    )) NOT NULL DEFAULT 'user',

    UNIQUE(username)
);

CREATE TABLE email (
    email_id        UUID            NOT NULL PRIMARY KEY,
    user_id         UUID            NOT NULL,
    local           VARCHAR(128)    NOT NULL,
    domain          VARCHAR(128)    NOT NULL,
    verified        BOOL            NOT NULL DEFAULT FALSE,

    FOREIGN KEY (user_id) REFERENCES users(user_id),
    UNIQUE(local, domain)
);
CREATE INDEX email_user ON email(user_id);

CREATE TABLE primary_email (
    user_id         UUID            NOT NULL PRIMARY KEY,
    email_id        UUID            NOT NULL,

    FOREIGN KEY (user_id)  REFERENCES users(user_id),
    FOREIGN KEY (email_id) REFERENCES email(email_id),
    unique(email_id)
);

CREATE TABLE hosts (
    host_id     UUID            NOT NULL PRIMARY KEY,
    hostname    VARCHAR(512)    NOT NULL,

    unique(hostname)
);

CREATE TABLE email_verification_codes (
    evcode_id       UUID            NOT NULL PRIMARY KEY,
    email_id        UUID            NOT NULL,

    FOREIGN KEY (email_id) REFERENCES email(email_id),

    unique(email_id)
);

CREATE TABLE sessions (
    session_id      UUID        NOT NULL PRIMARY KEY,
    active          BOOL        DEFAULT TRUE
);

CREATE TABLE session_hosts (
    session_host_id     UUID        NOT NULL PRIMARY KEY,
    session_id          UUID        NOT NULL,
    user_id             UUID,

    created             TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    accessed            TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    address             VARCHAR(128)    NOT NULL,
    agent               VARCHAR(128)    NOT NULL,

    FOREIGN KEY (user_id)    REFERENCES users(user_id),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),

    UNIQUE(session_id, address, agent)
);
CREATE INDEX session_hosts_session ON session_hosts(session_id);

CREATE TABLE api_keys (
    api_key_id      UUID            NOT NULL PRIMARY KEY,
    user_id         UUID            NOT NULL,
    name            VARCHAR(128)    NOT NULL,
    value           VARCHAR(16)     NOT NULL,

    status TEXT CHECK(status IN ('active', 'disabled', 'revoked')) NOT NULL,

    FOREIGN KEY (user_id) REFERENCES users(user_id),

    UNIQUE(value)
);
CREATE INDEX api_key_user ON api_keys(user_id);

CREATE TABLE log_files (
    log_file_id     UUID            NOT NULL PRIMARY KEY,
    name            TEXT            NOT NULL,

    local_file      TEXT,
    data            LONGBLOB
);

CREATE TABLE projects (
    project_id      UUID            NOT NULL PRIMARY KEY,
    name            VARCHAR(128)    NOT NULL,
    owner           UUID            DEFAULT NULL,

    FOREIGN KEY (owner) REFERENCES users(user_id),
    UNIQUE(name)
);

CREATE TABLE permissions (
    permission_id   UUID            NOT NULL PRIMARY KEY,
    project_id      UUID            NOT NULL,
    user_id         UUID            NOT NULL,
    updated         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    cpan_batch      INT          DEFAULT NULL,

    FOREIGN KEY (user_id)    REFERENCES users(user_id),
    FOREIGN KEY (project_id) REFERENCES projects(project_id),
    UNIQUE(project_id, user_id)
);

CREATE TABLE runs (
    run_ord         INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    run_id          UUID            NOT NULL,
    user_id         UUID            NOT NULL,


    status          TEXT            CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')) NOT NULL,
    worker_id       TEXT            DEFAULT NULL,

    error           TEXT            DEFAULT NULL,
    project_id      UUID            NOT NULL,

    pinned          BOOL            NOT NULL DEFAULT FALSE,
    has_coverage    BOOL            NOT NULL DEFAULT FALSE,

    -- User Input
    added           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    duration        TEXT            DEFAULT NULL,
    log_file_id     UUID            DEFAULT NULL,

    mode            TEXT            CHECK(mode IN ('qvfds', 'qvfd', 'qvf', 'summary', 'complete')) NOT NULL,
    buffer          TEXT            CHECK(buffer IN ('none', 'diag', 'job', 'run')) NOT NULL,

    -- From Log
    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,
    concurrency     INTEGER         DEFAULT NULL,
    parameters      JSON            DEFAULT NULL,

    FOREIGN KEY (user_id)     REFERENCES users(user_id),
    FOREIGN KEY (project_id)  REFERENCES projects(project_id),
    FOREIGN KEY (log_file_id) REFERENCES log_files(log_file_id)
);
CREATE INDEX run_run_id ON runs(run_id);
CREATE INDEX run_projects ON runs(project_id);
CREATE INDEX run_status ON runs(status);
CREATE INDEX run_user ON runs(user_id);

CREATE TABLE sweeps (
    sweep_id        UUID            NOT NULL PRIMARY KEY,
    run_id          UUID            NOT NULL,
    name            VARCHAR(255)    NOT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id),

    UNIQUE(run_id, name)
);
CREATE INDEX sweep_runs ON sweeps(run_id);

CREATE TABLE run_fields (
    run_field_id    UUID            NOT NULL PRIMARY KEY,
    run_id          UUID            NOT NULL,
    name            VARCHAR(255)    NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id),

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
    job_ord         INT         NOT NULL,
    run_id          UUID        NOT NULL,

    is_harness_out  BOOL        NOT NULL DEFAULT 0,

    status TEXT CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')) NOT NULL,

    parameters      JSON        DEFAULT NULL,
    fields          JSON        DEFAULT NULL,

    test_file_id    UUID        DEFAULT NULL,

    -- Summaries
    name            TEXT            DEFAULT NULL,
    fail            BOOL            DEFAULT NULL,
    retry           BOOL            DEFAULT NULL,
    exit_code       INT             DEFAULT NULL,
    launch          TIMESTAMP,
    start           TIMESTAMP,
    ended           TIMESTAMP,

    duration        DOUBLE PRECISION    DEFAULT NULL,

    pass_count      INT          DEFAULT NULL,
    fail_count      INT          DEFAULT NULL,

    -- Coverage
    coverage_manager    TEXT        DEFAULT NULL,

    -- Output data
    stdout          LONGTEXT        DEFAULT NULL,
    stderr          LONGTEXT        DEFAULT NULL,

    FOREIGN KEY (run_id)       REFERENCES runs(run_id),
    FOREIGN KEY (test_file_id) REFERENCES test_files(test_file_id),

    UNIQUE(job_id, job_try)
);
CREATE INDEX job_runs ON jobs(run_id);
CREATE INDEX job_fail ON jobs(fail);
CREATE INDEX job_file ON jobs(test_file_id);

CREATE TABLE job_fields (
    job_field_id    UUID            NOT NULL PRIMARY KEY,
    job_key         UUID            NOT NULL,
    name            VARCHAR(512)    NOT NULL,
    data            JSON            DEFAULT NULL,
    details         TEXT            DEFAULT NULL,
    raw             TEXT            DEFAULT NULL,
    link            TEXT            DEFAULT NULL,

    FOREIGN KEY (job_key) REFERENCES jobs(job_key),

    UNIQUE(job_key, name)
);


CREATE TABLE events (
    event_id        UUID        NOT NULL PRIMARY KEY,

    job_key         UUID        NOT NULL,

    event_ord       BIGINT      NOT NULL,

    has_binary      BOOL        NOT NULL DEFAULT FALSE,
    is_subtest      BOOL        NOT NULL DEFAULT FALSE,
    is_diag         BOOL        NOT NULL DEFAULT FALSE,
    is_harness      BOOL        NOT NULL DEFAULT FALSE,
    is_time         BOOL        NOT NULL DEFAULT FALSE,

    stamp           TIMESTAMP,

    parent_id       UUID        DEFAULT NULL,
    trace_id        CHAR(36)    DEFAULT NULL,
    nested          INT         DEFAULT 0,

    render          JSON        DEFAULT NULL,

    UNIQUE(event_ord, job_key),
    FOREIGN KEY (job_key) REFERENCES jobs(job_key)
);
CREATE INDEX event_event_id ON events(event_id);
CREATE INDEX event_job      ON events(job_key, is_subtest);
CREATE INDEX event_trace    ON events(trace_id);
CREATE INDEX event_parent   ON events(parent_id);

CREATE TABLE binaries (
    binary_id       UUID            NOT NULL PRIMARY KEY,
    event_id        UUID            NOT NULL,
    filename        VARCHAR(512)    NOT NULL,
    description     TEXT            DEFAULT NULL,
    is_image        BOOL            NOT NULL DEFAULT FALSE,
    data            LONGBLOB        NOT NULL,

    FOREIGN KEY (event_id)        REFERENCES events(event_id)
);
CREATE INDEX binaries_event ON binaries(event_id);

CREATE TABLE source_files (
    source_file_id  UUID         NOT NULL PRIMARY KEY,
    filename        VARCHAR(256) NOT NULL,

    UNIQUE(filename)
);

CREATE TABLE source_subs (
    source_sub_id   UUID         NOT NULL PRIMARY KEY,
    subname         VARCHAR(512) NOT NULL,

    UNIQUE(subname)
);

CREATE TABLE coverage_manager (
    coverage_manager_id   UUID         NOT NULL PRIMARY KEY,
    package               VARCHAR(256) NOT NULL,

    UNIQUE(package)
);

CREATE TABLE coverage (
    coverage_id     UUID        NOT NULL PRIMARY KEY,

    run_id              UUID        NOT NULL,
    test_file_id        UUID        NOT NULL,
    source_file_id      UUID        NOT NULL,
    source_sub_id       UUID        NOT NULL,
    coverage_manager_id UUID        DEFAULT NULL,
    job_key             UUID        DEFAULT NULL,

    metadata    JSON    DEFAULT NULL,

    FOREIGN KEY (run_id)              REFERENCES runs(run_id),
    FOREIGN KEY (test_file_id)        REFERENCES test_files(test_file_id),
    FOREIGN KEY (source_file_id)      REFERENCES source_files(source_file_id),
    FOREIGN KEY (source_sub_id)       REFERENCES source_subs(source_sub_id),
    FOREIGN KEY (coverage_manager_id) REFERENCES coverage_manager(coverage_manager_id),
    FOREIGN KEY (job_key)             REFERENCES jobs(job_key),

    UNIQUE(run_id, test_file_id, source_file_id, source_sub_id, job_key)
);
CREATE INDEX coverage_from_source ON coverage(source_file_id, source_sub_id);
CREATE INDEX coverage_from_run_source ON coverage(run_id, source_file_id, source_sub_id);
CREATE INDEX coverage_from_job ON coverage(job_key);

CREATE TABLE reporting (
    reporting_id    UUID                NOT NULL PRIMARY KEY,
    run_ord         INT                 NOT NULL,
    job_try         INT                 DEFAULT NULL,
    subtest         VARCHAR(512)        DEFAULT NULL,
    duration        DOUBLE PRECISION    NOT NULL,

    fail            SMALLINT    NOT NULL DEFAULT 0,
    pass            SMALLINT    NOT NULL DEFAULT 0,
    retry           SMALLINT    NOT NULL DEFAULT 0,
    abort           SMALLINT    NOT NULL DEFAULT 0,

    project_id      UUID        NOT NULL,
    run_id          UUID        NOT NULL,
    user_id         UUID        NOT NULL,
    job_key         UUID        DEFAULT NULL,
    test_file_id    UUID        DEFAULT NULL,
    event_id        UUID        DEFAULT NULL,

    FOREIGN KEY (project_id)      REFERENCES projects(project_id),
    FOREIGN KEY (run_id)          REFERENCES runs(run_id),
    FOREIGN KEY (user_id)         REFERENCES users(user_id),
    FOREIGN KEY (job_key)         REFERENCES jobs(job_key),
    FOREIGN KEY (test_file_id)    REFERENCES test_files(test_file_id),
    FOREIGN KEY (event_id)        REFERENCES events(event_id)
);
CREATE INDEX reporting_user ON reporting(user_id);
CREATE INDEX reporting_run  ON reporting(run_id);
CREATE INDEX reporting_a    ON reporting(project_id);
CREATE INDEX reporting_b    ON reporting(project_id, user_id);
CREATE INDEX reporting_e    ON reporting(project_id, test_file_id, subtest, user_id, run_ord);

CREATE TABLE resource_batch (
    resource_batch_id   UUID            NOT NULL PRIMARY KEY,
    run_id              UUID            NOT NULL,
    host_id             UUID            NOT NULL,
    stamp               TIMESTAMP(4)    NOT NULL,

    FOREIGN KEY (run_id)  REFERENCES runs(run_id),
    FOREIGN KEY (host_id) REFERENCES hosts(host_id)
);
CREATE INDEX resource_batch_run ON resource_batch(run_id);

CREATE TABLE resources (
    resource_id         UUID            NOT NULL PRIMARY KEY,
    resource_batch_id   UUID            NOT NULL,
    batch_ord           INT             NOT NULL,
    module              VARCHAR(512)    NOT NULL,
    data                JSON            NOT NULL,

    FOREIGN KEY (resource_batch_id) REFERENCES resource_batch(resource_batch_id),
    UNIQUE(resource_batch_id, batch_ord)
);

CREATE TABLE facets (
    event_id    UUID        NOT NULL PRIMARY KEY,

    data        JSON        DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id)
);

CREATE TABLE orphans (
    event_id    UUID        NOT NULL PRIMARY KEY,

    data        JSON        DEFAULT NULL,
    line        BIGINT      DEFAULT NULL,

    FOREIGN KEY (event_id) REFERENCES events(event_id)
);

CREATE TABLE run_parameters (
    run_id              UUID    NOT NULL PRIMARY KEY,
    parameters          JSON    DEFAULT NULL,

    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

CREATE TABLE job_parameters (
    job_key             UUID    NOT NULL PRIMARY KEY,
    parameters          JSON    DEFAULT NULL,

    FOREIGN KEY (job_key) REFERENCES jobs(job_key)
);
