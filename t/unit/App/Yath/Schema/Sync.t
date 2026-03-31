use Test2::V0; # -target => 'App::Yath::Schema::Sync'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

require App::Yath::Schema::Sync;

can_ok(
    'App::Yath::Schema::Sync',
    [qw/ sync run_delta write_sync read_sync get_runs /],
    'has expected sync methods'
);

done_testing;
