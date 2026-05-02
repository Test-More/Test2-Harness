use Test2::V0;

use File::Spec ();
BEGIN {
    @INC = map { File::Spec->rel2abs($_) } @INC;
    $ENV{PERL5LIB} = join(
        ':',
        (grep { !ref } @INC),
        (defined $ENV{PERL5LIB} ? ($ENV{PERL5LIB}) : ()),
    );
}

use File::Temp qw/tempdir tempfile/;
use Cwd        qw/getcwd/;


use App::Yath2::Command::test;

package Fake::Workspace2;
sub new                  { bless { workdir => $_[1] }, $_[0] }
sub workdir              { $_[0]->{workdir} }
sub create_option        { }
sub keep_dirs            { 0 }

package Fake::IPC2;
sub new       { bless {}, $_[0] }
sub file      { undef }
sub dir       { undef }
sub dir_order { [qw/cwd tempdir/] }
sub protocol  { undef }

package Fake::Yath2;
sub new              { bless {uuid => $_[1], cwd => $_[2]}, $_[0] }
sub instance_uuid    { $_[0]->{uuid} }
sub base_dir         { '' }
sub cwd              { $_[0]->{cwd} }
sub user_config_file { '' }
sub config_file      { '' }
sub project          { 'fakeproj' }
sub user             { 'fakeuser' }

package Fake::Renderer2;
# Forced verbose=>1 so the renderer emits per-assert lines (this test
# inspects the assertion text).
sub new { bless {verbose => 1, @_[1..$#_]} => $_[0] }
sub theme   { 'App::Yath2::Theme::Default' }
sub qvf     { 0 }
sub verbose { $_[0]->{verbose} }
sub quiet   { 0 }
sub wrap    { 1 }
sub server  { undef }
sub classes { {'App::Yath2::Renderer::Default' => []} }
sub all     { %{$_[0]} }

package Fake::Term2;
sub new { bless {color => 0, @_[1..$#_]} => $_[0] }
sub color { $_[0]->{color} }
sub all   { %{$_[0]} }

package Fake::Finder2;
sub new        { bless {}, $_[0] }
sub extensions { [qw/t t2/] }

package Fake::Resource2;
sub new       { bless {}, $_[0] }
sub classes   { return {'Test2::Harness2::Resource::JobCount' => []} }
sub slots     { 1 }
sub job_slots { 1 }

package Fake::Tests2;
sub new           { bless {}, $_[0] }
sub set_hash_seed { undef }

package Fake::LogArchive2;
sub new  { bless {}, $_[0] }
sub file { undef }
sub dir  { undef }

package Fake::Settings2;

sub new {
    my ($class, $workspace, $uuid, $cwd, %extras) = @_;
    bless {
        workspace   => $workspace,
        ipc         => Fake::IPC2->new,
        yath        => Fake::Yath2->new($uuid, $cwd),
        renderer    => Fake::Renderer2->new(%{$extras{renderer} // {}}),
        term        => Fake::Term2->new(%{$extras{term}     // {}}),
        finder      => Fake::Finder2->new,
        resource    => Fake::Resource2->new,
        tests       => Fake::Tests2->new,
        log_archive => Fake::LogArchive2->new,
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

my $tf = "$tmp/quick.t";
open my $fh, '>', $tf or die "Cannot write $tf: $!";
print $fh "use Test2::V0; ok(1, 'a passing assertion'); done_testing;\n";
close $fh;

my $cwd_dir = "$tmp/cwd";
mkdir $cwd_dir or die "mkdir cwd_dir: $!";
my $work = "$tmp/work";
mkdir $work or die "mkdir work: $!";

my $orig_cwd = getcwd();
chdir $cwd_dir or die "chdir cwd_dir: $!";

my $cmd = App::Yath2::Command::test->new(
    args     => [$tf],
    settings => Fake::Settings2->new(Fake::Workspace2->new($work), 'a1b2c3d4', $cwd_dir),
);

# Renderer::Default clones the real STDOUT fd via clone_io(\*STDOUT), so
# select() alone does not capture its output.  We must redirect at the fd
# level before the renderer is constructed (inside run()).
my ($cap_fh, $cap_file) = tempfile(UNLINK => 1, SUFFIX => '.out');
open(my $save_stdout, '>&', \*STDOUT) or die "dup STDOUT: $!";
open(STDOUT, '>&', $cap_fh) or die "redirect STDOUT: $!";
STDOUT->autoflush(1);

my $rc;
my $err;
my $ok = eval { $rc = $cmd->run; 1 };
$err = $@;

open(STDOUT, '>&', $save_stdout) or die "restore STDOUT: $!";
close $save_stdout;
close $cap_fh;

chdir $orig_cwd;
die $err unless defined $rc;

open(my $rh, '<', $cap_file) or die "read capture: $!";
my $out = do { local $/; <$rh> };
close $rh;

is($rc, 0, 'test command exits 0 for a passing test');

# The renderer should produce human-readable output, not raw JSON event blobs.
unlike($out, qr/"facet_data"/, 'no raw JSON event blobs in output');
unlike($out, qr/^\{/m,        'no bare JSON objects on their own lines');

# Renderer::Default injects a PASSED info line when harness_job_end arrives.
like($out, qr/PASSED/, 'PASSED marker appears in rendered output');

# The assertion name from the inner test should flow through the renderer.
like($out, qr/a passing assertion/, 'assertion details visible in rendered output');

done_testing;
