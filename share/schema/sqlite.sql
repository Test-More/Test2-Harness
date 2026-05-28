-- Test2::Harness2 SQLite schema.
-- Categories: local-state (collector, socket), common (account, project,
-- version, test_file), logged (runner, service, run, job, try, subtest,
-- artifact).
--
-- UUIDs are stored as BLOB (16 bytes) on flavors without a native uuid type.
-- v7 UUIDs are generated in Perl with Test2::Util::UUID; DBIx::QuickORM's
-- UUID autotype packs/unpacks the canonical string form to/from the 16-byte
-- blob via the column's binary affinity, so callers always see the canonical
-- hyphenated string.
--
-- The run table additionally carries a STORED GENERATED column,
-- run_uuid_string, holding the human-readable form of run_uuid. It is
-- maintained by SQLite (never touched by the app) and is the only uuid
-- column humans are expected to look up directly, so it is indexed.
--
-- hi-res timestamps are REAL. booleans are INTEGER (0/1, NULL = undecided).
--
-- Column ordering convention: SQLite's row format is variable-width and
-- doesn't care, but PostgreSQL (and to a lesser extent MySQL) pad columns
-- to alignment boundaries, so per-table columns are ordered by fixed-width
-- descending and then variable-length last:
--   1. 8-byte fixed  (REAL timestamps; future BIGINT / TIMESTAMP)
--   2. UUIDs         (BLOB(16) here / BINARY(16) on MySQL / native uuid on PG)
--   3. 4-byte fixed  (INTEGER PKs, FKs, counters, booleans-as-int)
--   4. Variable      (TEXT, BLOB data)
-- Generated columns (run.run_uuid_string) go in the variable group.

-- ---- common ----
-- 'account' (not 'user') because USER is reserved in PostgreSQL, MySQL,
-- and MariaDB.
CREATE TABLE account (
    account_id INTEGER PRIMARY KEY AUTOINCREMENT,
    email      TEXT NOT NULL COLLATE NOCASE,
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
    project_id   INTEGER NOT NULL REFERENCES project(project_id),
    test_file    TEXT NOT NULL,
    UNIQUE(project_id, test_file)
);

-- ---- logged ----
CREATE TABLE runner (
    runner_uuid BLOB PRIMARY KEY
);

CREATE TABLE run (
    started         REAL,
    stopped         REAL,
    run_uuid        BLOB PRIMARY KEY,
    runner_uuid     BLOB REFERENCES runner(runner_uuid),
    account_id      INTEGER REFERENCES account(account_id),
    project_id      INTEGER REFERENCES project(project_id),
    version_id      INTEGER REFERENCES version(version_id),
    passed          INTEGER,
    run_uuid_string TEXT GENERATED ALWAYS AS (
        lower(
            substr(hex(run_uuid),  1,  8) || '-' ||
            substr(hex(run_uuid),  9,  4) || '-' ||
            substr(hex(run_uuid), 13,  4) || '-' ||
            substr(hex(run_uuid), 17,  4) || '-' ||
            substr(hex(run_uuid), 21, 12)
        )
    ) STORED
);
CREATE INDEX run_uuid_string_idx ON run(run_uuid_string);

CREATE TABLE service (
    started      REAL,
    stopped      REAL,
    service_uuid BLOB PRIMARY KEY,
    runner_uuid  BLOB NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     BLOB REFERENCES run(run_uuid),
    mode         TEXT CHECK(mode IN ('run','restart','stop','kill')),
    name         TEXT NOT NULL,
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     BLOB PRIMARY KEY,
    run_uuid     BLOB NOT NULL REFERENCES run(run_uuid),
    runner_uuid  BLOB REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       INTEGER
);

CREATE TABLE try (
    try_uuid     BLOB PRIMARY KEY,
    job_uuid     BLOB NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       INTEGER,
    should_retry INTEGER,
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid BLOB PRIMARY KEY,
    try_uuid     BLOB NOT NULL REFERENCES try(try_uuid),
    passed       INTEGER,
    name         TEXT
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid BLOB PRIMARY KEY,
    run_uuid      BLOB REFERENCES run(run_uuid),
    service_uuid  BLOB REFERENCES service(service_uuid),
    try_uuid      BLOB REFERENCES try(try_uuid),
    type          TEXT,
    name          TEXT,
    local_path    TEXT,
    data          BLOB,
    CHECK ((service_uuid IS NULL) <> (try_uuid IS NULL))
);
CREATE INDEX artifact_type_idx      ON artifact(type);
CREATE INDEX artifact_name_idx      ON artifact(name);
CREATE INDEX artifact_type_name_idx ON artifact(type, name);

-- ---- local state ----
CREATE TABLE collector (
    started      REAL,
    stopped      REAL,
    collector_id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_uuid BLOB NOT NULL REFERENCES service(service_uuid),
    runner_uuid  BLOB REFERENCES runner(runner_uuid),
    try_uuid     BLOB REFERENCES try(try_uuid),
    pid          INTEGER,
    child_pid    INTEGER,
    exit_code    INTEGER,
    exit_signal  INTEGER,
    mode         TEXT CHECK(mode IN ('run','kill')),
    CHECK ((runner_uuid IS NULL) <> (try_uuid IS NULL))
);

CREATE TABLE socket (
    service_uuid BLOB PRIMARY KEY REFERENCES service(service_uuid),
    type         TEXT CHECK(type IN ('INET','UNIX')),
    route        TEXT
);
