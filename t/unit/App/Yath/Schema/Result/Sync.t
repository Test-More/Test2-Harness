use Test2::V0; # -target => 'App::Yath::Schema::Sync'

# App::Yath::Schema::Sync is a standalone utility class (not a Result class).
# It requires DBI and other dependencies, so skip gracefully if unavailable.
eval { require App::Yath::Schema::Sync; 1 }
    or plan skip_all => "App::Yath::Schema::Sync not available: $@";

can_ok(
    'App::Yath::Schema::Sync',
    [qw/ run_delta get_runs /],
    'has expected methods'
);

done_testing;
