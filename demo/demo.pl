use strict;
use warnings;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use Test2::Harness::UI::Util qw/dbd_driver qdb_driver/;

use lib 'lib';
use DBIx::QuickDB;
use Test2::Harness::UI::Config;
use IO::Compress::Bzip2     qw($Bzip2Error bzip2);
use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use POSIX ":sys_wait_h";

my ($schema) = @ARGV;

$schema //= 'PostgreSQL';
require(pkg_to_file("Test2::Harness::UI::Schema::$schema"));

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => qdb_driver($schema), dbd_driver => dbd_driver($schema)});

$SIG{INT} = sub { $db = undef; exit 255 };

my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
$dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;

$db->load_sql(harness_ui => 'share/schema/' . $schema . '.sql');

my $dsn = $db->connect_string('harness_ui');
print "DBI_DSN: $dsn\n";

$ENV{HARNESS_UI_DSN} = $dsn;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => '',
    dbi_pass    => '',
    single_user => 1,
    show_user   => 1,
    email       => 'exodist7@gmail.com',
);

my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root', user_id => gen_uuid()});

my %projects;
#for my $file (qw/coverage.jsonl.bz2/) {
opendir(my $dh, 'demo') or die "Could not open demo dir";
for my $file (sort readdir($dh)) {
    next unless $file =~ m/\.bz2$/;

    load_file($file);
}

sub load_file {
    my ($file) = @_;

    my $project;
    if ($file =~ m/moose/i) {
        $project = 'Moose';
    }
    else {
        $project = $1 if $file =~ m/^([\w\d]+)/;
    }

    $project //= "oops";

    unless ($projects{$project}) {
        my $p = $config->schema->resultset('Project')->create({name => $project, project_id => gen_uuid()});
        $projects{$project} = $p;
    }

    my $run = $config->schema->resultset('Run')->create({
        run_id     => gen_uuid(),
        user_id    => $user->user_id,
        mode       => 'complete',
        buffer     => 'job',
        status     => 'pending',
        project_id => $projects{$project}->project_id,

        log_file => {
            log_file_id => gen_uuid(),
            name        => $file,
            local_file  => $file =~ m{^/} ? $file : "./demo/$file",
        },
    });

    return $run;
}

$ENV{YATH_UI_SCHEMA} = $schema;
my %commands = (
    importer1 => [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    importer2 => [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    importer3 => [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    importer4 => [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    importer5 => [$^X, '-Ilib', 'scripts/yath-ui-importer.pl', $dsn],
    starman  => ['starman', '-Ilib', '--port', 8081, '--workers', 20, './demo/demo.psgi'],
);
my $start = $$;
my %pids;

launch($_) for keys %commands;

sub launch {
    my $cmd = shift;

    last unless $start == $$;

    my $pid = fork();
    die "Failed to fork" unless defined $pid;

    if ($pid) {
        $pids{$cmd} = $pid;
        return;
    }
    else {
        my $run = $commands{$cmd};
        exec(@$run);
    }

    exit 255;
}

while (1) {
    last unless $start == $$;

    print "DBI_DSN: $dsn\n";


    chomp(my $in = <>);
    $in ||= 'starman';

    exit 0 if $in eq 'exit' || $in eq 'q';

    if ($in =~ m/^l\s+(.*)$/) {
        load_file($1);
        next;
    }

    if ($in eq 'db') {
        $db->shell('harness_ui');
        next;
    }

    if (my $pid = delete $pids{$in}) {
        print "Restarting $in...\n";
        kill('TERM', $pid);
        waitpid($pid, 0);
        launch($in);
        next;
    }

    warn "Invalid command '$in'\n" unless $in eq 'h' || $in eq 'help' || $in eq '?';
    print <<"    EOT";
Valid Commands:
    [enter]  - restart starman
    starman  - restart starman
    importer - restart the importer
    db       - launch db shell
    l <file> - load a log file
    exit     - exit
    q        - exit
    help     - this help
    h        - this help
    ?        - this help
    EOT
}

exit 0;
