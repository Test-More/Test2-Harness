use Test2::V0; # -target => 'App::Yath::Schema::Importer'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

require App::Yath::Schema::Importer;

can_ok(
    'App::Yath::Schema::Importer',
    [qw/ config worker_id spawn run process /],
    'has all expected methods'
);

subtest 'requires config attribute' => sub {
    ok(dies { App::Yath::Schema::Importer->new() }, "constructor dies without config");
};

done_testing;
