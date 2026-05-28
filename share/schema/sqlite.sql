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
-- Timestamps are DATETIME (second precision) stored as ISO-8601 TEXT, e.g.
-- "2026-05-28 03:07:11". DBIx::QuickORM's DateTime autotype activates on the
-- DATETIME sql_type and formats DateTime objects via DateTime::Format::SQLite;
-- the harness passes DateTime objects through Test2::Harness2::Util::now_dt.
-- Sub-second resolution is only needed for individual test events, which are
-- captured in events.jsonl.zst artifacts (lossless), not in these row stamps.
-- Booleans are BOOLEAN (3-state: NULL = undecided / not yet known, 0 = false,
-- 1 = true). A CHECK constraint enforces the 3-state semantic; PG gets this
-- for free from its native BOOLEAN type, MySQL/MariaDB rely on the CHECK
-- (BOOLEAN there is TINYINT(1)).
--
-- Column ordering convention: SQLite's row format is variable-width and
-- doesn't care, but PostgreSQL (and to a lesser extent MySQL) pad columns
-- to alignment boundaries, so per-table columns are ordered by fixed-width
-- descending and then variable-length last:
--   1. 8-byte fixed  (future BIGINT)
--   2. UUIDs         (BLOB(16) here / BINARY(16) on MySQL / native uuid on PG)
--   3. 4-byte fixed  (INTEGER PKs, FKs, counters)
--   4. 1-byte fixed  (BOOLEAN)
--   5. Variable      (TEXT, DATETIME, BLOB data)
-- Generated columns (run.run_uuid_string) go in the variable group.
--
-- Caveat: this is the common-practice "size descending" heuristic, which
-- is adequate for all supported flavors but is not strictly optimal for
-- PostgreSQL — there, the optimal rule is alignment-descending (uuid is
-- 1-byte char-aligned in PG, varlena is 4-byte aligned), so a strict PG
-- pass would move uuids past varlena. The savings are minor and the
-- size-descending rule is more readable across flavors; revisit if a
-- table grows enough rows for the padding to matter in production.

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
    runner_uuid BLOB(16) PRIMARY KEY
);

CREATE TABLE run (
    run_uuid        BLOB(16) PRIMARY KEY,
    runner_uuid     BLOB(16) REFERENCES runner(runner_uuid),
    account_id      INTEGER REFERENCES account(account_id),
    project_id      INTEGER REFERENCES project(project_id),
    version_id      INTEGER REFERENCES version(version_id),
    passed          BOOLEAN CHECK(passed IN (0, 1)),
    started         DATETIME,
    stopped         DATETIME,
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
    service_uuid BLOB(16) PRIMARY KEY,
    runner_uuid  BLOB(16) NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     BLOB(16) REFERENCES run(run_uuid),
    mode         TEXT CHECK(mode IN ('run','restart','stop','kill')),
    name         TEXT NOT NULL,
    started      DATETIME,
    stopped      DATETIME,
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     BLOB(16) PRIMARY KEY,
    run_uuid     BLOB(16) NOT NULL REFERENCES run(run_uuid),
    runner_uuid  BLOB(16) REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       BOOLEAN CHECK(passed IN (0, 1))
);

CREATE TABLE try (
    try_uuid     BLOB(16) PRIMARY KEY,
    job_uuid     BLOB(16) NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    should_retry BOOLEAN CHECK(should_retry IN (0, 1)),
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid BLOB(16) PRIMARY KEY,
    try_uuid     BLOB(16) NOT NULL REFERENCES try(try_uuid),
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    name         TEXT
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid BLOB(16) PRIMARY KEY,
    run_uuid      BLOB(16) REFERENCES run(run_uuid),
    service_uuid  BLOB(16) REFERENCES service(service_uuid),
    try_uuid      BLOB(16) REFERENCES try(try_uuid),
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
    collector_id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_uuid BLOB(16) NOT NULL REFERENCES service(service_uuid),
    runner_uuid  BLOB(16) REFERENCES runner(runner_uuid),
    try_uuid     BLOB(16) REFERENCES try(try_uuid),
    pid          INTEGER,
    child_pid    INTEGER,
    exit_code    INTEGER,
    exit_signal  INTEGER,
    mode         TEXT CHECK(mode IN ('run','kill')),
    started      DATETIME,
    stopped      DATETIME,
    CHECK ((runner_uuid IS NULL) <> (try_uuid IS NULL))
);

CREATE TABLE socket (
    service_uuid BLOB(16) PRIMARY KEY REFERENCES service(service_uuid),
    type         TEXT CHECK(type IN ('INET','UNIX')),
    route        TEXT
);
