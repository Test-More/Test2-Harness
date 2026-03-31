use Test2::V0; # -target => 'App::Yath::Schema::RunProcessor'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

require App::Yath::Schema::RunProcessor;

can_ok(
    'App::Yath::Schema::RunProcessor',
    [qw/ config process_lines process_event flush populate /],
    'has expected processing methods'
);

done_testing;
