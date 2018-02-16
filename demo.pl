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

$db->load_sql(harness_ui => 'schema/postgresql.sql');

my $dsn = $db->connect_string('harness_ui');
print "DBI_DSN: $dsn\n";

$ENV{HARNESS_UI_DSN} = $dsn;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => '',
    dbi_pass    => '',
    single_user => 1,
);

my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root'});

my $dash_error = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'Bad Logs',
        user_id           => $user->user_id,    #UUID        NOT NULL REFERENCES users(user_id),
        weight            => -100,                #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 0,                 #BOOL        NOT NULL,
        show_failures     => 0,                 #BOOL        NOT NULL,
        show_shared       => 0,                 #BOOL        NOT NULL,
        show_pending      => 0,                 #BOOL        NOT NULL,
        show_protected    => 0,                 #BOOL        NOT NULL,
        show_public       => 0,                 #BOOL        NOT NULL,
        show_signoff_only => 0,                 #BOOL        NOT NULL,
        show_errors_only  => 1,
        show_mine         => 1,
        show_project      => undef,             #CITEXT      DEFAULT NULL,
        show_version      => undef,             #CITEXT      DEFAULT NULL
        show_columns      => ["date", "uploaded_by", "name", "status", "error"],
    }
);


my $dash_sign = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'Require Signoff',
        user_id           => $user->user_id,    #UUID        NOT NULL REFERENCES users(user_id),
        weight            => -2,                #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 1,                 #BOOL        NOT NULL,
        show_failures     => 1,                 #BOOL        NOT NULL,
        show_shared       => 1,                 #BOOL        NOT NULL,
        show_pending      => 1,                 #BOOL        NOT NULL,
        show_protected    => 1,                 #BOOL        NOT NULL,
        show_public       => 1,                 #BOOL        NOT NULL,
        show_signoff_only => 1,                 #BOOL        NOT NULL,
        show_errors_only  => 0,
        show_mine         => 1,
        show_project      => undef,             #CITEXT      DEFAULT NULL,
        show_version      => undef,             #CITEXT      DEFAULT NULL
        show_columns      => ["passed", "failed", "project", "version", "date", "uploaded_by", "name", "status"],
    }
);

my $dash_shared = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'Shared With Me',
        user_id           => $user->user_id,    #UUID        NOT NULL REFERENCES users(user_id),
        weight            => -1,                #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 1,                 #BOOL        NOT NULL,
        show_failures     => 1,                 #BOOL        NOT NULL,
        show_shared       => 1,                 #BOOL        NOT NULL,
        show_pending      => 1,                 #BOOL        NOT NULL,
        show_protected    => 0,                 #BOOL        NOT NULL,
        show_public       => 0,                 #BOOL        NOT NULL,
        show_signoff_only => 0,                 #BOOL        NOT NULL,
        show_errors_only  => 0,
        show_project      => undef,             #CITEXT      DEFAULT NULL,
        show_version      => undef,             #CITEXT      DEFAULT NULL
        show_mine         => 0,
        show_columns      => ["passed", "failed", "project", "version", "date", "uploaded_by", "name", "status"],
    }
);

my $dash_my = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'My Runs',
        user_id           => $user->user_id,    #UUID        NOT NULL REFERENCES users(user_id),
        weight            => 0,                 #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 1,                 #BOOL        NOT NULL,
        show_failures     => 1,                 #BOOL        NOT NULL,
        show_shared       => 0,                 #BOOL        NOT NULL,
        show_pending      => 1,                 #BOOL        NOT NULL,
        show_protected    => 0,                 #BOOL        NOT NULL,
        show_public       => 0,                 #BOOL        NOT NULL,
        show_signoff_only => 0,                 #BOOL        NOT NULL,
        show_errors_only  => 0,
        show_project      => undef,             #CITEXT      DEFAULT NULL,
        show_version      => undef,             #CITEXT      DEFAULT NULL
        show_mine         => 1,
        show_columns      => ["passed", "failed", "project", "version", "date", "uploaded_by", "name", "status"],
    }
);

my $dash_protected = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'Protected Runs',
        user_id           => $user->user_id,     #UUID        NOT NULL REFERENCES users(user_id),
        weight            => 1,                  #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 1,                  #BOOL        NOT NULL,
        show_failures     => 1,                  #BOOL        NOT NULL,
        show_pending      => 1,                  #BOOL        NOT NULL,
        show_shared       => 0,                 #BOOL        NOT NULL,
        show_protected    => 1,                  #BOOL        NOT NULL,
        show_public       => 0,                  #BOOL        NOT NULL,
        show_signoff_only => 0,                  #BOOL        NOT NULL,
        show_errors_only  => 0,
        show_project      => undef,              #CITEXT      DEFAULT NULL,
        show_version      => undef,              #CITEXT      DEFAULT NULL
        show_mine         => 0,
        show_columns      => ["passed", "failed", "project", "version", "date", "uploaded_by", "name", "status"],
    }
);

my $dash_public = $config->schema->resultset('Dashboard')->create(
    {
        name              => 'Public Runs',
        user_id           => $user->user_id,     #UUID        NOT NULL REFERENCES users(user_id),
        weight            => 2,                  #SMALLINT    NOT NULL DEFAULT 0,
        show_passes       => 1,                  #BOOL        NOT NULL,
        show_failures     => 1,                  #BOOL        NOT NULL,
        show_pending      => 1,                  #BOOL        NOT NULL,
        show_shared       => 0,                 #BOOL        NOT NULL,
        show_protected    => 0,                  #BOOL        NOT NULL,
        show_public       => 1,                  #BOOL        NOT NULL,
        show_signoff_only => 0,                  #BOOL        NOT NULL,
        show_errors_only  => 0,
        show_project      => undef,              #CITEXT      DEFAULT NULL,
        show_version      => undef,              #CITEXT      DEFAULT NULL
        is_public         => 1,
        show_mine         => 0,
        show_columns      => ["passed", "failed", "project", "version", "date", "uploaded_by", "name", "status"],
    }
);

my @runs;
my @perms = qw/public protected private/;
for my $file (qw/moose.jsonl.bz2 simple-fail.jsonl.bz2  simple-pass.jsonl.bz2 fake.jsonl.bz2/) {
    my $fh = IO::Uncompress::Bunzip2->new("./demo/$file") or die "Could not open bz2 file: $Bunzip2Error";
    my $log_data;
    bzip2 $fh => \$log_data or die "IO::Compress::Bzip2 failed: $Bzip2Error";

    my ($project, $version);
    if ($file =~ m/moose/) {
        $project = 'Moose';
        $version = '2.2009';
    }
    else {
        $project = 'Simple';
        $version = $file =~ m/pass/ ? 'pass' : 'fail';
    }

    push @runs => $config->schema->resultset('Run')->create(
        {
            user_id       => $user->user_id,
            name          => $file,
            permissions   => shift @perms || 'public',
            mode          => 'qvfd',
            store_facets  => 'fail',
            store_orphans => 'fail',
            log_file      => $file,
            log_data      => $log_data,
            status        => 'pending',
            project       => $project,
            version       => $version,
        }
    );
}

$config->schema->resultset('Signoff')->create(
    {
        run_id       => $runs[0]->run_id,
        requested_by => $user->user_id,
    }
);

$config->schema->resultset('RunShare')->create(
    {
        run_id  => $runs[0]->run_id,
        user_id => $user->user_id,
    }
);

$config->schema->resultset('RunShare')->create(
    {
        run_id  => $runs[1]->run_id,
        user_id => $user->user_id,
    }
);

my @commands = (
    [$^X, '-Ilib', 'author_tools/run_imports.pl', $dsn],
    ['plackup', '-Ilib', '-r', './demo.psgi'],
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
