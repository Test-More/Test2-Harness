use Test2::V0; # -target => 'App::Yath::Schema::ResultSet'

eval { require DBIx::Class::ResultSet; 1 }
    or plan skip_all => "DBIx::Class not available: $@";

require App::Yath::Schema::ResultSet;

isa_ok(
    'App::Yath::Schema::ResultSet',
    ['DBIx::Class::ResultSet'],
    'inherits from DBIx::Class::ResultSet'
);

can_ok(
    'App::Yath::Schema::ResultSet',
    ['find_by_id_or_uuid'],
    'has find_by_id_or_uuid method'
);

done_testing;
