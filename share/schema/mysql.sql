-- Test2::Harness2 MySQL schema. Mirrors share/schema/sqlite.sql.
-- UUIDs are BINARY(16); run_uuid_string is a STORED generated column holding
-- the canonical hyphenated form (LOWER(CONCAT(SUBSTR(HEX(run_uuid),...))))
-- and is indexed for human lookup. This HEX/SUBSTR/CONCAT expression is
-- portable across MySQL 8+ and MariaDB (BIN_TO_UUID is not available in all
-- MariaDB versions or in GENERATED columns on older builds).
-- Timestamps are DATETIME (second precision). Booleans are 3-state
-- (NULL = undecided, 0, 1) enforced by a CHECK. When the DDL changes, every
-- flavor file under share/schema/ moves together.
--
-- Column-level REFERENCES are parsed but not enforced by MySQL/InnoDB; they
-- document intended foreign-key relationships only.
--
-- TEXT columns that participate in UNIQUE constraints or indexes are widened to
-- VARCHAR(n) because MySQL/MariaDB cannot index unbounded TEXT without a prefix
-- length. account.email uses utf8mb4's default case-insensitive collation in
-- place of SQLite's COLLATE NOCASE.

-- ---- common ----
-- 'account' (not 'user') because USER is reserved in PostgreSQL, MySQL,
-- and MariaDB.
CREATE TABLE account (
    account_id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    email      VARCHAR(255) NOT NULL,
    UNIQUE(email)
);

CREATE TABLE project (
    project_id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(255) NOT NULL,
    UNIQUE(name)
);

CREATE TABLE version (
    version_id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(project_id),
    version    VARCHAR(255) NOT NULL,
    UNIQUE(project_id, version)
);

CREATE TABLE test_file (
    test_file_id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id   INTEGER NOT NULL REFERENCES project(project_id),
    test_file    VARCHAR(512) NOT NULL,
    UNIQUE(project_id, test_file)
);

-- ---- logged ----
CREATE TABLE runner (
    runner_uuid BINARY(16) PRIMARY KEY
);

CREATE TABLE run (
    run_uuid        BINARY(16) PRIMARY KEY,
    runner_uuid     BINARY(16) REFERENCES runner(runner_uuid),
    account_id      INTEGER REFERENCES account(account_id),
    project_id      INTEGER REFERENCES project(project_id),
    version_id      INTEGER REFERENCES version(version_id),
    passed          BOOLEAN CHECK(passed IN (0, 1)),
    started         DATETIME,
    stopped         DATETIME,
    run_uuid_string VARCHAR(36) GENERATED ALWAYS AS (
        LOWER(CONCAT(
            SUBSTR(HEX(run_uuid),  1,  8), '-',
            SUBSTR(HEX(run_uuid),  9,  4), '-',
            SUBSTR(HEX(run_uuid), 13,  4), '-',
            SUBSTR(HEX(run_uuid), 17,  4), '-',
            SUBSTR(HEX(run_uuid), 21, 12)
        ))
    ) STORED
);
CREATE INDEX run_uuid_string_idx ON run(run_uuid_string);

CREATE TABLE service (
    service_uuid BINARY(16) PRIMARY KEY,
    runner_uuid  BINARY(16) NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     BINARY(16) REFERENCES run(run_uuid),
    mode         VARCHAR(16) CHECK(mode IN ('run','restart','stop','kill')),
    name         VARCHAR(255) NOT NULL,
    started      DATETIME,
    stopped      DATETIME,
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     BINARY(16) PRIMARY KEY,
    run_uuid     BINARY(16) NOT NULL REFERENCES run(run_uuid),
    runner_uuid  BINARY(16) REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       BOOLEAN CHECK(passed IN (0, 1))
);

CREATE TABLE try (
    try_uuid     BINARY(16) PRIMARY KEY,
    job_uuid     BINARY(16) NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    should_retry BOOLEAN CHECK(should_retry IN (0, 1)),
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid BINARY(16) PRIMARY KEY,
    try_uuid     BINARY(16) NOT NULL REFERENCES try(try_uuid),
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    name         VARCHAR(255)
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid BINARY(16) PRIMARY KEY,
    run_uuid      BINARY(16) REFERENCES run(run_uuid),
    service_uuid  BINARY(16) REFERENCES service(service_uuid),
    try_uuid      BINARY(16) REFERENCES try(try_uuid),
    type          VARCHAR(255),
    name          VARCHAR(255),
    local_path    VARCHAR(1024),
    data          LONGBLOB,
    CHECK ((service_uuid IS NULL) <> (try_uuid IS NULL))
);
CREATE INDEX artifact_type_idx      ON artifact(type);
CREATE INDEX artifact_name_idx      ON artifact(name);
CREATE INDEX artifact_type_name_idx ON artifact(type, name);

-- ---- local state ----
CREATE TABLE collector (
    collector_id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    service_uuid BINARY(16) NOT NULL REFERENCES service(service_uuid),
    runner_uuid  BINARY(16) REFERENCES runner(runner_uuid),
    try_uuid     BINARY(16) REFERENCES try(try_uuid),
    pid          INTEGER,
    child_pid    INTEGER,
    exit_code    INTEGER,
    exit_signal  INTEGER,
    mode         VARCHAR(16) CHECK(mode IN ('run','kill')),
    started      DATETIME,
    stopped      DATETIME,
    CHECK ((runner_uuid IS NULL) <> (try_uuid IS NULL))
);

CREATE TABLE socket (
    service_uuid BINARY(16) PRIMARY KEY REFERENCES service(service_uuid),
    type         VARCHAR(8) CHECK(type IN ('INET','UNIX')),
    route        VARCHAR(1024)
);
