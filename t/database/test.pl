use Test2::Plugin::IsolateTemp;
use Test2::V0;
use Test2::Require::Module 'Test2::Plugin::Cover' => '0.000022';
use App::Yath::Schema::Config;
use App::Yath::Server;
use App::Yath::Tester qw/yath/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

my $dir = __FILE__;
$dir =~ s{/?[^/]+$}{}g;
$dir =~ s{^\./}{};

my $config = App::Yath::Schema::Config->new(ephemeral => $main::DRIVER);
my $server = App::Yath::Server->new(schema_config => $config);
my $db = $server->start_ephemeral_db;
my $dsn = $db->connect_string('harness_ui');;

my @yath_args = (
    '--db-dsn'  => $dsn,
    '--project' => 'test',
    '--db-publisher' => 'root',
    '--publish-mode' => 'complete',
    '--renderer' => 'DB',
    '--publish-user' => 'root',
);

yath(
    command => 'test',
    pre     => ['-D./lib'],
    exit    => T(),
    args    => [
        "-D",
        "-I$dir/lib",
        "$dir/inner",
        '--ext=tx',
        '-v',
        @yath_args,
        '--cover-files',
        '--cover-metrics',
        '--retry' => 1,
    ],
);

my $schema = $config->schema;

my ($run, @other) = $schema->resultset('Run')->all();
ok(!@other, "Only 1 run");

is($run->jobs->count, 3, "2 jobs + harness output job");

my %seen;
for my $job ($run->jobs->all) {
    for my $try ($job->job_tries->all) {
        $seen{$job->shortest_file}++;
    }
}

is(
    \%seen,
    {
        'HARNESS INTERNAL LOG' => 1,
        'pass.tx'              => 1,
        'fail.tx'              => 2,
    },
    "Got all jobs and retries"
);

done_testing;
