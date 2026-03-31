use Test2::V0; # -target => 'App::Yath::Schema::Result::Host'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

isa_ok(
    'App::Yath::Schema::Result::Host',
    ['App::Yath::Schema::ResultBase'],
    'inherits from ResultBase'
);

can_ok(
    'App::Yath::Schema::Result::Host',
    ['TO_JSON', 'get_all_fields'],
    'has ResultBase methods'
);

done_testing;
