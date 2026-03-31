use Test2::V0;

eval { require DBIx::Class::Core; 1 }
    or plan skip_all => "DBIx::Class not available: $@";

require App::Yath::Schema::ResultBase;

isa_ok(
    'App::Yath::Schema::ResultBase',
    ['DBIx::Class::Core'],
    'inherits from DBIx::Class::Core'
);

can_ok(
    'App::Yath::Schema::ResultBase',
    ['get_all_fields', 'get_inflated_columns', 'TO_JSON'],
    'has required methods'
);

# get_all_fields must be an alias for get_inflated_columns
is(
    App::Yath::Schema::ResultBase->can('get_all_fields'),
    App::Yath::Schema::ResultBase->can('get_inflated_columns'),
    'get_all_fields is aliased to get_inflated_columns'
);

done_testing;
