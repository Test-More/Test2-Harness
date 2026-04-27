use Test2::V0;

# TODO: macOS pipe-buffer deadlock — IPC peers go away mid-handshake
# because F_SETPIPE_SZ is Linux-only and AtomicPipe FIFOs stay at the
# kernel default. Re-enable once Test2::Harness2::Resource::PipeLimits
# (commit 2c7cc9d7a) is wired up. Refs: AI_DOCS/2026-04-25-atomic-pipe-fifo.md.
plan skip_all => "TODO: macOS IPC pipe-buffer deadlock (see AI_DOCS/2026-04-25-atomic-pipe-fifo.md)"
    if $^O eq 'darwin';

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

use App::Yath2::Command::test;
use App::Yath2::LogArchive;

package Fake::Workspace;
sub new           { bless {workdir => $_[1]}, $_[0] }
sub workdir       { $_[0]->{workdir} }
sub create_option { }

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

package Fake::Settings;

sub new {
    my ($class, $workspace, $uuid, $cwd, %extras) = @_;
    bless {
        workspace => $workspace,
        ipc       => Fake::IPC->new,
        yath      => Fake::Yath->new($uuid, $cwd),
        renderer  => Fake::Renderer->new(%{$extras{renderer} // {}}),
        term      => Fake::Term->new(%{$extras{term}     // {}}),
    } => $class;
}
sub workspace   { $_[0]->{workspace} }
sub ipc         { $_[0]->{ipc} }
sub yath        { $_[0]->{yath} }
sub renderer    { $_[0]->{renderer} }
sub term        { $_[0]->{term} }
sub check_group { exists $_[0]->{$_[1]} ? 1 : 0 }

package main;

my $tmp = tempdir(CLEANUP => 1);
my $tf  = "$tmp/quick.t";
open my $fh, '>', $tf or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

# Use a separate cwd so the archive lands somewhere we control and can clean up.
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

my @archives = glob "$cwd_dir/*.yath";
is(scalar(@archives), 1, 'exactly one archive produced in cwd');
my ($archive) = @archives;
like($archive, qr{/\d{8}-\d{6}\.yath\z}, 'archive name uses YYYYMMDD-HHMMSS pattern');

my $la    = App::Yath2::LogArchive->new(path => $archive);
my %files = map { $_ => 1 } $la->list_files;

ok($files{'services/harness.jsonl.zst'}, 'archive contains harness JSONL log');
ok($files{'services/harness.json.zst'},  'archive contains harness JSON  log');
ok($files{'artifacts.json.zst'},         'archive contains global artifacts manifest');
ok(
    (grep { m{^runs/[^/]+/artifacts\.json\.zst\z} } keys %files),
    'archive contains a per-run artifacts manifest'
);
ok(
    (grep { m{^runs/[^/]+/tests/[^/]+\.jsonl\.zst\z} } keys %files),
    'archive contains at least one per-job JSONL'
);
ok(
    (grep { m{^runs/[^/]+/tests/[^/]+\.json\.zst\z} } keys %files),
    'archive contains at least one per-job JSON'
);

done_testing;
