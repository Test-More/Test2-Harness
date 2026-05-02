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
use Time::HiRes ();
use POSIX       ();
use IPC::Manager qw/ipcm_connect/;

# Isolate the per-cwd index Phase 8.3 writes from this command's run.
my $idx_root = tempdir(CLEANUP => 1);
$ENV{XDG_RUNTIME_DIR} = $idx_root;

use App::Yath2::Command::test;
use App::Yath2::Util::IPC qw/read_ipc_file/;

# ---- Minimal fake settings ---------------------------------------------------

package Fake::IPCGroup;
sub new       { bless {dir => $_[1], dir_order => $_[2]}, $_[0] }
sub file      { undef }
sub dir       { $_[0]->{dir} }
sub dir_order { $_[0]->{dir_order} }
sub protocol  { undef }

package Fake::YathGroup;
sub new              { bless {uuid => $_[1], base_dir => $_[2], cwd => $_[3]}, $_[0] }
sub instance_uuid    { $_[0]->{uuid} }
sub base_dir         { $_[0]->{base_dir} }
sub cwd              { $_[0]->{cwd} }
sub user_config_file { '' }
sub config_file      { '' }
sub project          { 'fakeproj' }
sub user             { 'fakeuser' }

package Fake::Workspace;
sub new                  { bless {workdir => $_[1]}, $_[0] }
sub workdir              { $_[0]->{workdir} }
sub create_option        { }
sub keep_dirs            { 0 }

package Fake::RendererGroup;
sub new { bless {verbose => 0, @_[1..$#_]} => $_[0] }
sub theme   { 'App::Yath2::Theme::Default' }
sub qvf     { 0 }
sub verbose { $_[0]->{verbose} }
sub quiet   { 0 }
sub wrap    { 1 }
sub server  { undef }
sub classes { {'App::Yath2::Renderer::Default' => []} }
sub all     { %{$_[0]} }

package Fake::TermGroup;
sub new { bless {color => 0, @_[1..$#_]} => $_[0] }
sub color { $_[0]->{color} }
sub all   { %{$_[0]} }

package Fake::FinderGroup;
sub new        { bless {}, $_[0] }
sub extensions { [qw/t t2/] }

package Fake::ResourceGroup;
sub new       { bless {}, $_[0] }
sub classes   { return {'Test2::Harness2::Resource::JobCount' => []} }
sub slots     { 1 }
sub job_slots { 1 }

package Fake::TestsGroup;
sub new           { bless {}, $_[0] }
sub set_hash_seed { undef }

package Fake::LogArchiveGroup;
sub new  { bless {}, $_[0] }
sub file { undef }
sub dir  { undef }

package Fake::Settings;

sub new {
    my ($class, %a) = @_;
    $a{renderer}    //= Fake::RendererGroup->new;
    $a{term}        //= Fake::TermGroup->new;
    $a{finder}      //= Fake::FinderGroup->new;
    $a{resource}    //= Fake::ResourceGroup->new;
    $a{tests}       //= Fake::TestsGroup->new;
    $a{log_archive} //= Fake::LogArchiveGroup->new;
    return bless \%a => $class;
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

# ---- Test body ---------------------------------------------------------------

my $tmp       = tempdir(CLEANUP => 1);
my $work      = "$tmp/work";
my $ipc_dir   = "$tmp/ipc";
my $test_uuid = 'a1b2c3d4';

mkdir $work    or die "mkdir work: $!";
mkdir $ipc_dir or die "mkdir ipc_dir: $!";

my $test_file = "$tmp/pass.t";
open(my $fh, '>', $test_file) or die "open: $!";
print {$fh} "use Test2::V0; ok 1; done_testing;\n";
close $fh;

my $tf = "$tmp/quick.t";
open $fh, '>', $tf or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $settings = Fake::Settings->new(
    workspace => Fake::Workspace->new($work),
    ipc       => Fake::IPCGroup->new($ipc_dir, []),
    yath      => Fake::YathGroup->new($test_uuid, $tmp, $tmp),
);

# Run Command::test in a child so we can poll the IPC dir while it runs.
my $child_pid = fork // die "fork: $!";
if (!$child_pid) {
    # Child: run the command, redirect stdout to /dev/null to avoid
    # polluting the test output.
    open(STDOUT, '>', '/dev/null') or POSIX::_exit(2);
    my $cmd = App::Yath2::Command::test->new(
        args     => [$tf],
        settings => $settings,
    );
    my $ok = eval { $cmd->run; 1 };
    POSIX::_exit($ok ? 0 : 1);
}

# Parent: poll the ipc_dir for the IPC info file.
my $info_path;
for (1 .. 200) {
    opendir(my $dh, $ipc_dir) or last;
    while (defined(my $entry = readdir($dh))) {
        next unless $entry =~ /-yath-\d+-ipc\.json\z/;
        $info_path = File::Spec->catfile($ipc_dir, $entry);
        last;
    }
    closedir $dh;
    last if $info_path;
    Time::HiRes::sleep(0.05);
}

ok($info_path, 'IPC info file appeared while Command::test was running');

# Validate file contents.
if ($info_path) {
    my $rec = read_ipc_file($info_path);
    is($rec->{command}, 'test', 'command is test');
    ok($rec->{pid} > 0,   'pid populated');
    ok($rec->{ipcm_info}, 'ipcm_info populated');
    like($rec->{uuid}, qr/^[0-9a-f]{8}$/, 'uuid is 8 hex chars');
    is($rec->{uuid}, $test_uuid, 'uuid matches settings');

    # Connect to the IPC bus to confirm the route is valid.
    my $client;
    if (eval { $client = ipcm_connect('integration_test', $rec->{ipcm_info}); 1 }) {
        pass('ipcm_connect against the published ipcm_info succeeded');
        eval { $client->disconnect };
    }
    else {
        fail("ipcm_connect failed: $@");
    }
}

waitpid($child_pid, 0);

ok(!-e $info_path, 'IPC info file was removed when Command::test exited')
    if $info_path;

done_testing;
