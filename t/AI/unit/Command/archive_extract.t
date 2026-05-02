use Test2::V0;

use File::Path ();
use File::Spec ();
BEGIN { @INC = map { File::Spec->rel2abs($_) } @INC }

use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;

use App::Yath2::Command::archive;
use App::Yath2::Command::extract;
use App::Yath2::LogArchive;

# Minimal settings shape the extract / archive commands need.
package Fake::Yath;
sub new              { bless { cwd => $_[1] }, $_[0] }
sub cwd              { $_[0]->{cwd} }
sub project          { '__UNKNOWN__' }
sub user             { 'fakeuser' }
sub user_config_file { '' }
sub config_file      { '' }
package Fake::Extract;
sub new           { bless { no_decompress => 0 }, $_[0] }
sub no_decompress { $_[0]->{no_decompress} }
package Fake::Settings;
sub new {
    my ($class, %p) = @_;
    bless {
        yath    => Fake::Yath->new($p{cwd} // '/tmp/no-such-cwd'),
        extract => Fake::Extract->new,
    }, $class;
}
sub yath    { $_[0]->{yath} }
sub extract { $_[0]->{extract} }
package main;

# Build a logdir-shaped tree the archive command can serialise. The
# archive writer treats every regular file under $logdir as content
# to bundle and never re-compresses .zst entries.
sub _make_logdir {
    my $dir = tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/services/harness");
    open my $fh, '>', "$dir/services/harness/events.jsonl" or die $!;
    print $fh qq{{"event":"hi"}\n};
    close $fh;
    return $dir;
}

sub _run_cmd {
    my ($class, @args) = @_;
    my $cmd = $class->new(args => [@args], settings => Fake::Settings->new);
    my $out = '';
    my $orig = select;
    open(my $cap, '>', \$out) or die $!;
    select $cap;
    my $rc = eval { $cmd->run };
    my $err = $@;
    select $orig;
    close $cap;
    return ($rc, $out, $err);
}

subtest 'archive + extract round-trip via tar.zidx' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');
    is($rc,  0,  'archive: rc=0');
    ok(-s $arc, 'archive: output file non-empty');
    like($out, qr/Wrote archive/, 'archive: wrote message');

    my $dest = "$work/restored";
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');
    is($rc,  0,  'extract: rc=0');
    ok(-d $dest, 'extract: destination created');

    open my $rfh, '<', "$dest/services/harness/events.jsonl" or die $!;
    is(scalar(<$rfh>), qq{{"event":"hi"}\n}, 'extract: file contents intact');
};

subtest 'archive: default filename when only logdir given' => sub {
    my $logdir   = _make_logdir();
    my $work     = tempdir(CLEANUP => 1);
    my $orig_cwd = getcwd();
    chdir $work or die "chdir: $!";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', $logdir);
    chdir $orig_cwd;

    is($err, '', 'no exception');
    is($rc,  0,  'rc=0');

    # Phase 8: default destination is under the system tmpdir, NOT cwd.
    my @cwd_yath = glob "$work/*.yath";
    is(scalar(@cwd_yath), 0, 'no archive landed in cwd');

    my ($written) = $out =~ /Wrote archive: (\S+\.yath)/;
    ok($written, 'archive command reported a path');
    ok(-f $written, 'archive file exists at the reported path') if $written;
    like(
        $written,
        qr{/__UNKNOWN__-fakeuser-\d{8}-\d{6}-\d+\.yath\z},
        'name matches ${project}-${user}-${stamp}-${pid}.yath default',
    );

    unlink $written if defined $written && -f $written;
};

subtest 'archive: missing logdir errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive');
    like($err, qr/logdir is required/, 'logdir required');
};

subtest 'archive: bad logdir errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', '/no/such/logdir');
    like($err, qr/is not a directory/, 'bad logdir rejected');
};

subtest 'archive: extra positional arg errors' => sub {
    my $logdir = _make_logdir();
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive',
        $logdir, 'foo.yath', 'extra-arg');
    like($err, qr/extra arguments/, 'third positional arg rejected');
};

subtest 'extract: missing archive errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract');
    like($err, qr/archive_filename is required/, 'archive required');
};

subtest 'extract: nonexistent archive errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', '/no/such/file');
    like($err, qr/does not exist/, 'missing archive rejected');
};

subtest 'extract: existing destination errors' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive ok');

    mkdir "$work/dest" or die $!;
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc, "$work/dest");
    like($err, qr/already exists/, 'pre-existing destination rejected');
};

subtest 'extract: default destination is ./logs' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive ok');

    my $orig_cwd = getcwd();
    chdir $work or die "chdir: $!";
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc);
    chdir $orig_cwd;

    is($err, '', 'no exception');
    ok(-d "$work/logs", 'created ./logs');
    ok(-f "$work/logs/services/harness/events.jsonl", 'extracted into ./logs');
};

done_testing;
