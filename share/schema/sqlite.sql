-- Test2::Harness2 SQLite schema.
-- Categories: local-state (collector, socket), common (user, project,
-- version, test_file), logged (runner, service, run, job, try, subtest,
-- artifact). UUID columns are TEXT (v7 generated in Perl). hi-res
-- timestamps are REAL. booleans are INTEGER (0/1, NULL = undecided).

-- ---- common ----
-- NOTE: 'user' is a reserved word in PostgreSQL/MySQL; quote or rename it
-- when the other flavor files are written.
CREATE TABLE user (
    user_id INTEGER PRIMARY KEY AUTOINCREMENT,
    email   TEXT NOT NULL COLLATE NOCASE,
    UNIQUE(email)
);

CREATE TABLE project (
    project_id INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    UNIQUE(name)
);

CREATE TABLE version (
    version_id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES project(project_id),
    version    TEXT NOT NULL,
    UNIQUE(project_id, version)
);

CREATE TABLE test_file (
    test_file_id INTEGER PRIMARY KEY AUTOINCREMENT,
    test_file    TEXT NOT NULL,
    UNIQUE(test_file)
);

-- ---- logged ----
CREATE TABLE runner (
    runner_uuid TEXT PRIMARY KEY
);

CREATE TABLE run (
    run_uuid    TEXT PRIMARY KEY,
    runner_uuid TEXT REFERENCES runner(runner_uuid),
    user_id     INTEGER REFERENCES user(user_id),
    project_id  INTEGER REFERENCES project(project_id),
    version_id  INTEGER REFERENCES version(version_id),
    started     REAL,
    stopped     REAL,
    passed      INTEGER
);

CREATE TABLE service (
    service_uuid TEXT PRIMARY KEY,
    runner_uuid  TEXT NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     TEXT REFERENCES run(run_uuid),
    started      REAL,
    stopped      REAL,
    name         TEXT NOT NULL,
    mode         TEXT CHECK(mode IN ('run','restart','stop','kill')),
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     TEXT PRIMARY KEY,
    run_uuid     TEXT NOT NULL REFERENCES run(run_uuid),
    runner_uuid  TEXT REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       INTEGER
);

CREATE TABLE try (
    try_uuid     TEXT PRIMARY KEY,
    job_uuid     TEXT NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       INTEGER,
    should_retry INTEGER,
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid TEXT PRIMARY KEY,
    try_uuid     TEXT NOT NULL REFERENCES try(try_uuid),
    name         TEXT,
    passed       INTEGER
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid TEXT PRIMARY KEY,
    run_uuid      TEXT REFERENCES run(run_uuid),
    service_uuid  TEXT REFERENCES service(service_uuid),
    try_uuid      TEXT REFERENCES try(try_uuid),
    name          TEXT,
    type          TEXT,
    local_path    TEXT,
    data          BLOB,
    CHECK ((service_uuid IS NULL) <> (try_uuid IS NULL))
);
CREATE INDEX artifact_type_idx      ON artifact(type);
CREATE INDEX artifact_name_idx      ON artifact(name);
CREATE INDEX artifact_type_name_idx ON artifact(type, name);

-- ---- local state ----
CREATE TABLE collector (
    collector_id INTEGER PRIMARY KEY AUTOINCREMENT,
    runner_uuid  TEXT REFERENCES runner(runner_uuid),
    service_uuid TEXT NOT NULL REFERENCES service(service_uuid),
    try_uuid     TEXT REFERENCES try(try_uuid),
    pid          INTEGER,
    child_pid    INTEGER,
    started      REAL,
    stopped      REAL,
    mode         TEXT CHECK(mode IN ('run','kill')),
    error_code   INTEGER,
    signal       INTEGER,
    CHECK ((runner_uuid IS NULL) <> (try_uuid IS NULL))
);

CREATE TABLE socket (
    service_uuid TEXT PRIMARY KEY REFERENCES service(service_uuid),
    type         TEXT CHECK(type IN ('INET','UNIX')),
    route        TEXT
);
