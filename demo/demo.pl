use strict;
use warnings;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use lib 'lib';
use DBIx::QuickDB;
use Test2::Harness::UI::Import;
use Test2::Harness::UI::Config;
use IO::Compress::Bzip2     qw($Bzip2Error bzip2);
use IO::Uncompress::Bunzip2 qw($Bunzip2Error);

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});

$SIG{INT} = sub { $db = undef; exit 255 };

my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
$dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;

$db->load_sql(harness_ui => 'share/schema/postgresql.sql');

my $dsn = $db->connect_string('harness_ui');
print "DBI_DSN: $dsn\n";

$ENV{HARNESS_UI_DSN} = $dsn;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => '',
    dbi_pass    => '',
    single_user => 0,
    email       => 'exodist7@gmail.com',
);

my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});

my %projects;
my @runs;
my @modes = qw/complete complete complete complete/;
for my $file (qw/table.jsonl.bz2 moose.jsonl.bz2 tiny.jsonl.bz2 tap.jsonl.bz2 subtests.jsonl.bz2 simple-fail.jsonl.bz2 simple-pass.jsonl.bz2 fake.jsonl.bz2 large.jsonl.bz2/) {
    my $fh = IO::Uncompress::Bunzip2->new("./demo/$file") or die "Could not open bz2 file: $Bunzip2Error";
    my $log_data;
    bzip2 $fh => \$log_data or die "IO::Compress::Bzip2 failed: $Bzip2Error";

    my ($project, $version);
    if ($file =~ m/moose/) {
        $project = 'Moose';
        $version = '2.2009';
    }
    else {
        $project = $1 if $file =~ m/^([\w\d]+)/;
        $version = 'fail' if $file =~ m/fail/;
        $version = 'pass' if $file =~ m/pass/;
        $version ||= '123';
    }

    unless ($projects{$project}) {
        my $p = $config->schema->resultset('Project')->create({name => $project});
        $projects{$project} = $p;
    }

    push @runs => $config->schema->resultset('Run')->create(
        {
            user_id       => $user->user_id,
            mode          => shift @modes || 'qvfd',
            status        => 'pending',
            project_id    => $projects{$project}->project_id,
            version       => $version,

            log_file => {
                name => $file,
                data => $log_data,
            },
        }
    );
}

my @commands = (
    [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    ['starman', '-Ilib', '-r', '--port', 8081, './demo/demo.psgi'],
);

my $start = $$;
my @pids;
for my $cmd (@commands) {
    last unless $start == $$;

    my $pid = fork();
    die "Failed to fork" unless defined $pid;

    if ($pid) {
        push @pids => $pid;
        next;
    }
    else {
        exec(@$cmd);
    }
}

waitpid($_, 0) for @pids;

exit 0;
