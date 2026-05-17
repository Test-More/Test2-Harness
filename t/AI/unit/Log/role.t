use Test2::V0;

# Phase 1 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md §6)
# introduces App::Yath2::Role::Log as the formal Log API contract.
# Every Log backend must consume the role and supply every required
# method.

use App::Yath2::Role::Log;
use App::Yath2::Log::Live;
use App::Yath2::Log::Directory;
use App::Yath2::Log::TarZIdx;
use App::Yath2::Log::DB;

# 1. Role::Log is a Role::Tiny role.
ok(
    Role::Tiny->is_role('App::Yath2::Role::Log'),
    'App::Yath2::Role::Log is a Role::Tiny role',
);

# 2. The four canonical Log consumers DOES the role.
my @consumers = qw{
    App::Yath2::Log::Live
    App::Yath2::Log::Directory
    App::Yath2::Log::TarZIdx
    App::Yath2::Log::DB
};

for my $class (@consumers) {
    ok(
        $class->DOES('App::Yath2::Role::Log'),
        "$class consumes App::Yath2::Role::Log",
    );
}

# 3. Required-method list matches the documented Phase 1 contract plus the
# producer-iterator additions from 1C (run_producers / job_producers /
# service_producers / collector_producers).
my @expected_required = sort qw{
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts list_files
    run_producers job_producers service_producers collector_producers
    event events end_of_events reset
    extract archive
    absolute_path
    _artifact_exists _artifact_read _artifact_iter_records
    _artifact_list_dir _artifact_open_fh _artifact_save
};

# Role::Tiny stores requires under $Role::Tiny::INFO{$role}{requires}
# as an arrayref. Sort and compare to a stable list.
my $info = $Role::Tiny::INFO{'App::Yath2::Role::Log'};
ok(ref($info) eq 'HASH', 'Role::Tiny::INFO entry exists for the role');

my @actual_required = sort @{ $info->{requires} || [] };
is(
    \@actual_required,
    \@expected_required,
    'role requires-list matches Phase 1 contract',
);

# 4. Every consumer can satisfy every required method by name. (Role
# composition would have refused to apply otherwise -- this is a
# belt-and-braces check that nothing slipped through via AUTOLOAD or
# similar metaprogramming.)
for my $class (@consumers) {
    for my $m (@expected_required) {
        ok(
            $class->can($m),
            "$class can $m",
        );
    }
}

done_testing;
