use Test2::V0;

use File::Spec ();

BEGIN {
    @INC = map { File::Spec->rel2abs($_) } @INC;
    # Forked child processes spawned by the harness rely on PERL5LIB,
    # not the parent's runtime @INC -- without this, test fixtures
    # spawned after our chdir cannot find this worktree's modules.
    $ENV{PERL5LIB} = join(
        ':',
        (grep { !ref } @INC),
        (defined $ENV{PERL5LIB} ? ($ENV{PERL5LIB}) : ()),
    );
}

use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;

# Isolate the per-cwd index that Phase 8.3 writes; otherwise this
# integration test pollutes the real user's index entry on every run.
my $idx_root = tempdir(CLEANUP => 1);
$ENV{XDG_RUNTIME_DIR} = $idx_root;

use App::Yath2::Command::test;
use App::Yath2::LogArchive;

package Fake::Workspace;
sub new                  { bless {workdir => $_[1]}, $_[0] }
sub workdir              { $_[0]->{workdir} }
sub create_option        { }
sub keep_dirs            { 0 }

package Fake::IPC;
sub new       { bless {}, $_[0] }
sub file      { undef }
sub dir       { undef }
sub dir_order { [qw/cwd tempdir/] }
sub protocol  { undef }

package Fake::Yath;
sub new              { bless {uuid => $_[1], cwd => $_[2]}, $_[0] }
sub instance_uuid    { $_[0]->{uuid} }
sub base_dir         { '' }
sub cwd              { $_[0]->{cwd} }
sub user_config_file { '' }
sub config_file      { '' }
sub project          { 'fakeproj' }
sub user             { 'fakeuser' }

package Fake::Renderer;
sub new { bless {verbose => 0, @_[1..$#_]} => $_[0] }
sub theme   { 'App::Yath2::Theme::Default' }
sub qvf     { 0 }
sub verbose { $_[0]->{verbose} }
sub quiet   { 0 }
sub wrap    { 1 }
sub server  { undef }
sub classes { {'App::Yath2::Renderer::Default' => []} }
sub all     { %{$_[0]} }

package Fake::Term;
sub new { bless {color => 0, @_[1..$#_]} => $_[0] }
sub color { $_[0]->{color} }
sub all   { %{$_[0]} }

package Fake::Finder;
sub new        { bless {}, $_[0] }
sub extensions { [qw/t t2/] }

package Fake::Resource;
sub new       { bless {}, $_[0] }
sub classes   { return {'Test2::Harness2::Resource::JobCount' => []} }
sub slots     { 1 }
sub job_slots { 1 }

package Fake::Tests;
sub new           { bless {}, $_[0] }
sub set_hash_seed { undef }

package Fake::LogArchive;
sub new  { bless {}, $_[0] }
sub file { undef }
sub dir  { undef }

package Fake::Settings;

sub new {
    my ($class, $workspace, $uuid, $cwd, %extras) = @_;
    bless {
        workspace   => $workspace,
        ipc         => Fake::IPC->new,
        yath        => Fake::Yath->new($uuid, $cwd),
        renderer    => Fake::Renderer->new(%{$extras{renderer} // {}}),
        term        => Fake::Term->new(%{$extras{term}     // {}}),
        finder      => Fake::Finder->new,
        resource    => Fake::Resource->new,
        tests       => Fake::Tests->new,
        log_archive => Fake::LogArchive->new,
    } => $class;
}
sub workspace   { $_[0]->{workspace} }
sub ipc         { $_[0]->{ipc} }
sub yath        { $_[0]->{yath} }
sub renderer    { $_[0]->{renderer} }
sub term        { $_[0]->{term} }
sub finder      { $_[0]->{finder} }
sub resource    { $_[0]->{resource} }
sub tests       { $_[0]->{tests} }
sub log_archive { $_[0]->{log_archive} }
sub check_group { exists $_[0]->{$_[1]} ? 1 : 0 }

package main;

my $tmp = tempdir(CLEANUP => 1);
my $tf  = "$tmp/quick.t";
open my $fh, '>', $tf or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

# Use a separate cwd so the test does not write near the worktree --
# under the new default the archive does NOT land in cwd, so we want to
# be able to assert that nothing was created here.
my $cwd_dir = "$tmp/cwd";
mkdir $cwd_dir or die $!;
my $work = "$tmp/work";
mkdir $work or die $!;

my $orig_cwd = getcwd();
chdir $cwd_dir or die "chdir: $!";

my $cmd = App::Yath2::Command::test->new(
    args     => [$tf],
    settings => Fake::Settings->new(Fake::Workspace->new($work), 'a1b2c3d4', $cwd_dir),
);

my $captured = '';
my $rc;
my $err;
{
    open(my $cap, '>', \$captured) or die $!;
    my $orig_out = select $cap;
    my $ok       = eval { $rc = $cmd->run; 1 };
    $err = $@;
    select $orig_out;
}

chdir $orig_cwd;
die $err unless defined $rc;

is($rc, 0, 'test command exits 0 on a passing test');

unlike($captured, qr/Work directory:/, 'no Work directory: line printed');
like($captured, qr/Wrote archive: .*\.yath/, 'reported written archive');

ok(!-d $work, 'workdir was removed after archiving');

# Archive lives in tempdir; only the last_log.yath symlink lands in cwd.
my @cwd_real = grep { ! -l $_ } glob "$cwd_dir/*.yath";
is(scalar(@cwd_real), 0, 'no real archive file written into cwd');
ok(-l "$cwd_dir/last_log.yath", 'last_log.yath symlink created in cwd');

my ($archive_line) = $captured =~ /Wrote archive: (\S+\.yath)/;
ok($archive_line, 'captured the archive path that was written');
ok(-f $archive_line, 'archive exists at the reported path') if $archive_line;
my $archive = $archive_line;
like(
    $archive,
    qr{/fakeproj-fakeuser-\d{8}-\d{6}-\d+\.yath\z},
    'archive name uses ${project}-${user}-${stamp}-${pid}.yath pattern',
);

my $la    = App::Yath2::LogArchive->open(path => $archive);
my %files = map { $_ => 1 } $la->list_files;

ok($files{'services/harness/events.jsonl.zst'}, 'archive contains harness JSONL log');
ok($files{'services/harness/state.json.zst'},   'archive contains harness JSON  log');
ok(
    (grep { m{^runs/[^/]+/tests/[^/]+/\d+\.jsonl\.zst\z} } keys %files),
    'archive contains at least one per-try JSONL (runs/<run>/tests/<job>/<try>.jsonl.zst)'
);
ok(
    (grep { m{^runs/[^/]+/tests/[^/]+/\d+\.json\.zst\z} } keys %files),
    'archive contains at least one per-try JSON (runs/<run>/tests/<job>/<try>.json.zst)'
);

# The default archive destination is now under the system tmpdir,
# outside the test's CLEANUP-managed tempdir; clean it up explicitly.
unlink $archive if defined $archive && -f $archive;

done_testing;
