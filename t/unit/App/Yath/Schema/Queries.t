use Test2::V0; # -target => 'App::Yath::Schema::Queries'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

require App::Yath::Schema::Queries;

can_ok(
    'App::Yath::Schema::Queries',
    [qw/ projects versions categories tiers builds /],
    'has all query methods'
);

done_testing;
