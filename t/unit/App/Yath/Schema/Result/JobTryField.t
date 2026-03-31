use Test2::V0; # -target => 'App::Yath::Schema::Result::JobTryField'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

isa_ok(
    'App::Yath::Schema::Result::JobTryField',
    ['App::Yath::Schema::ResultBase'],
    'inherits from ResultBase'
);

can_ok(
    'App::Yath::Schema::Result::JobTryField',
    ['TO_JSON', 'get_all_fields'],
    'has ResultBase methods'
);

done_testing;
