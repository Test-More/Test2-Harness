package App::Yath::Test::DBIC::Schema;
use strict;
use warnings;

use Test2::V0;

use Exporter 'import';
our @EXPORT_OK = qw/run_schema_tests/;

use App::Yath::Test::DBIC::Database qw/ephemeral_server/;

sub run_schema_tests {
    my (%args) = @_;
    my $driver = $args{driver} or die "driver required\n";

    my ($config, $server, $dsn) = ephemeral_server(driver => $driver);
    my $schema = $config->schema;

    subtest "load $driver schema" => sub {
        ok($schema, "schema connected for $driver");
    };

    subtest 'every Result class is loadable' => sub {
        my @sources = sort $schema->sources;
        ok(@sources >= 20, 'at least 20 sources registered') or diag "got @sources sources";
        for my $source_name (@sources) {
            my $rs = eval { $schema->resultset($source_name) };
            ok($rs, "resultset $source_name") or diag $@;
        }
    };

    subtest 'User password methods' => sub {
        my $users = $schema->resultset('User');
        my $u = $users->create({ username => 'test_user_' . $$, password => 'hunter2', role => 'user' });
        ok($u->verify_password('hunter2'), 'verify_password accepts correct');
        ok(!$u->verify_password('wrong'),  'verify_password rejects wrong');
        $u->delete;
    };
}

1;
