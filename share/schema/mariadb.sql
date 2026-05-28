-- Test2::Harness2 MariaDB schema. Mirrors share/schema/sqlite.sql.
-- MariaDB (10.7+) has a native `uuid` type, so UUID columns are stored in
-- human-readable form and the run_uuid_string generated column is not needed
-- here (mirroring PostgreSQL). Timestamps are DATETIME (second precision).
-- Booleans are 3-state (NULL = undecided, 0, 1) enforced by a CHECK.
-- Column-level REFERENCES are parsed but not enforced by MariaDB/InnoDB; they
-- document intended foreign-key relationships only. When the DDL changes,
-- every flavor file under share/schema/ moves together.
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
    runner_uuid uuid PRIMARY KEY
);

CREATE TABLE run (
    run_uuid    uuid PRIMARY KEY,
    runner_uuid uuid REFERENCES runner(runner_uuid),
    account_id  INTEGER REFERENCES account(account_id),
    project_id  INTEGER REFERENCES project(project_id),
    version_id  INTEGER REFERENCES version(version_id),
    passed      BOOLEAN CHECK(passed IN (0, 1)),
    started     DATETIME,
    stopped     DATETIME
);

CREATE TABLE service (
    service_uuid uuid PRIMARY KEY,
    runner_uuid  uuid NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     uuid REFERENCES run(run_uuid),
    mode         VARCHAR(16) CHECK(mode IN ('run','restart','stop','kill')),
    name         VARCHAR(255) NOT NULL,
    started      DATETIME,
    stopped      DATETIME,
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     uuid PRIMARY KEY,
    run_uuid     uuid NOT NULL REFERENCES run(run_uuid),
    runner_uuid  uuid REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       BOOLEAN CHECK(passed IN (0, 1))
);

CREATE TABLE try (
    try_uuid     uuid PRIMARY KEY,
    job_uuid     uuid NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    should_retry BOOLEAN CHECK(should_retry IN (0, 1)),
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid uuid PRIMARY KEY,
    try_uuid     uuid NOT NULL REFERENCES try(try_uuid),
    passed       BOOLEAN CHECK(passed IN (0, 1)),
    name         VARCHAR(255)
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid uuid PRIMARY KEY,
    run_uuid      uuid REFERENCES run(run_uuid),
    service_uuid  uuid REFERENCES service(service_uuid),
    try_uuid      uuid REFERENCES try(try_uuid),
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
    service_uuid uuid NOT NULL REFERENCES service(service_uuid),
    runner_uuid  uuid REFERENCES runner(runner_uuid),
    try_uuid     uuid REFERENCES try(try_uuid),
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
    service_uuid uuid PRIMARY KEY REFERENCES service(service_uuid),
    type         VARCHAR(8) CHECK(type IN ('INET','UNIX')),
    route        VARCHAR(1024)
);
