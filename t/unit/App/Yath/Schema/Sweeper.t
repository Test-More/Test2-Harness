use Test2::V0; # -target => 'App::Yath::Schema::Sweeper'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

require App::Yath::Schema::Sweeper;

can_ok(
    'App::Yath::Schema::Sweeper',
    [qw/ config sweep sweep_run sweep_job /],
    'has expected sweep methods'
);

done_testing;
