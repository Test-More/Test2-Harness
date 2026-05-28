-- Test2::Harness2 PostgreSQL schema. Mirrors share/schema/sqlite.sql.
-- UUIDs use the native uuid type (no run_uuid_string generated column needed --
-- run_uuid is already human-readable and indexed as the primary key).
-- Timestamps use `timestamp` (without time zone); all stamps are written in
-- server-local time via Test2::Harness2::Util::now_dt.
-- Booleans are native 3-state (NULL = undecided, false, true). When the DDL
-- changes, every flavor file under share/schema/ moves together.
--
-- 'account' (not 'user') because USER is reserved in PostgreSQL.
-- The account.email uniqueness is enforced via a functional index on
-- lower(email) so that lookups are case-insensitive without COLLATE NOCASE.

-- ---- common ----
CREATE TABLE account (
    account_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email      text NOT NULL
);
CREATE UNIQUE INDEX account_email_lower_idx ON account (lower(email));

CREATE TABLE project (
    project_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL,
    UNIQUE(name)
);

CREATE TABLE version (
    version_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(project_id),
    version    text NOT NULL,
    UNIQUE(project_id, version)
);

CREATE TABLE test_file (
    test_file_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id   INTEGER NOT NULL REFERENCES project(project_id),
    test_file    text NOT NULL,
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
    passed      boolean,
    started     timestamp,
    stopped     timestamp
);
-- No run_uuid_string column/index: PostgreSQL's native uuid PK is already
-- human-readable and indexed, so the SQLite generated-string column is not needed here.

CREATE TABLE service (
    service_uuid uuid PRIMARY KEY,
    runner_uuid  uuid NOT NULL REFERENCES runner(runner_uuid),
    run_uuid     uuid REFERENCES run(run_uuid),
    mode         text CHECK(mode IN ('run','restart','stop','kill')),
    name         text NOT NULL,
    started      timestamp,
    stopped      timestamp,
    UNIQUE(name, runner_uuid, run_uuid)
);

CREATE TABLE job (
    job_uuid     uuid PRIMARY KEY,
    run_uuid     uuid NOT NULL REFERENCES run(run_uuid),
    runner_uuid  uuid REFERENCES runner(runner_uuid),
    test_file_id INTEGER NOT NULL REFERENCES test_file(test_file_id),
    passed       boolean
);

CREATE TABLE try (
    try_uuid     uuid PRIMARY KEY,
    job_uuid     uuid NOT NULL REFERENCES job(job_uuid),
    ord          INTEGER NOT NULL,
    passed       boolean,
    should_retry boolean,
    UNIQUE(job_uuid, ord)
);

CREATE TABLE subtest (
    subtest_uuid uuid PRIMARY KEY,
    try_uuid     uuid NOT NULL REFERENCES try(try_uuid),
    passed       boolean,
    name         text
);

-- run_uuid is denormalized here (derivable via service/try -> run) so
-- finalize_run can collect a run's artifacts without a join.
CREATE TABLE artifact (
    artifact_uuid uuid PRIMARY KEY,
    run_uuid      uuid REFERENCES run(run_uuid),
    service_uuid  uuid REFERENCES service(service_uuid),
    try_uuid      uuid REFERENCES try(try_uuid),
    type          text,
    name          text,
    local_path    text,
    data          bytea,
    CHECK ((service_uuid IS NULL) <> (try_uuid IS NULL))
);
CREATE INDEX artifact_type_idx      ON artifact(type);
CREATE INDEX artifact_name_idx      ON artifact(name);
CREATE INDEX artifact_type_name_idx ON artifact(type, name);

-- ---- local state ----
CREATE TABLE collector (
    collector_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_uuid uuid NOT NULL REFERENCES service(service_uuid),
    runner_uuid  uuid REFERENCES runner(runner_uuid),
    try_uuid     uuid REFERENCES try(try_uuid),
    pid          INTEGER,
    child_pid    INTEGER,
    exit_code    INTEGER,
    exit_signal  INTEGER,
    mode         text CHECK(mode IN ('run','kill')),
    started      timestamp,
    stopped      timestamp,
    CHECK ((runner_uuid IS NULL) <> (try_uuid IS NULL))
);

CREATE TABLE socket (
    service_uuid uuid PRIMARY KEY REFERENCES service(service_uuid),
    type         text CHECK(type IN ('INET','UNIX')),
    route        text
);
