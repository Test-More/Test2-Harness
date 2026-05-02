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

# Intercept JobCount->new and TestFile->new BEFORE loading the test
# command so we can prove the parsed -j / -x values reach the spawn
# call and the per-file constructor without actually starting a
# harness service.
my @captured_jobcount;
my @captured_testfiles;

require Test2::Harness2::Resource::JobCount;
{
    no warnings 'redefine';
    my $orig = \&Test2::Harness2::Resource::JobCount::new;
    *Test2::Harness2::Resource::JobCount::new = sub {
        my ($class, %p) = @_;
        push @captured_jobcount => \%p;
        return $orig->($class, %p);
    };
}

require Test2::Harness2::TestFile;
{
    no warnings 'redefine';
    my $orig = \&Test2::Harness2::TestFile::new;
    *Test2::Harness2::TestFile::new = sub {
        my ($class, %p) = @_;
        push @captured_testfiles => \%p;
        return $orig->($class, %p);
    };
}

# Stub Test2::Harness2->spawn so we never start a service. We only
# care about what arguments the test command passed in.
require Test2::Harness2;
{
    no warnings 'redefine';
    *Test2::Harness2::spawn = sub {
        my ($class, %p) = @_;
        die "EARLY_EXIT\n" . join(',', map { "$_=" . ($p{$_} // '') } sort keys %p) . "\n";
    };
}

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

package Fake::Resource2;
sub new       { my ($c, %p) = @_; bless {slots => $p{slots}, job_slots => $p{job_slots}} => $c }
sub slots     { $_[0]->{slots} }
sub job_slots { $_[0]->{job_slots} }
sub classes   { return {'Test2::Harness2::Resource::JobCount' => []} }

package Fake::Finder2;
sub new        { bless {}, $_[0] }
sub extensions { [qw/t t2/] }

package Fake::Tests2;
sub new           { bless {}, $_[0] }
sub set_hash_seed { undef }

package Fake::LogArchive2;
sub new  { bless {}, $_[0] }
sub file { undef }
sub dir  { undef }

package Fake::Yath2Group;
sub new     { bless {}, $_[0] }
sub project { 'fakeproj' }
sub user    { 'fakeuser' }

package Fake::Settings2;
sub new {
    my ($class, $workspace, $resource) = @_;
    bless {
        workspace   => $workspace,
        ipc         => Fake::IPC2->new,
        resource    => $resource,
        finder      => Fake::Finder2->new,
        tests       => Fake::Tests2->new,
        log_archive => Fake::LogArchive2->new,
        yath        => Fake::Yath2Group->new,
    } => $class;
}
sub workspace   { $_[0]->{workspace} }
sub ipc         { $_[0]->{ipc} }
sub resource    { $_[0]->{resource} }
sub finder      { $_[0]->{finder} }
sub tests       { $_[0]->{tests} }
sub log_archive { $_[0]->{log_archive} }
sub yath        { $_[0]->{yath} }
sub check_group { exists $_[0]->{$_[1]} ? 1 : 0 }

package main;

my $tmp = tempdir(CLEANUP => 1);
my $tf = "$tmp/q.t";
open my $fh, '>', $tf or die "open $tf: $!";
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;
my $work = "$tmp/work";
mkdir $work or die "mkdir $work: $!";

sub run_with_resource {
    my ($slots, $job_slots) = @_;
    @captured_jobcount  = ();
    @captured_testfiles = ();
    my $cmd = App::Yath2::Command::test->new(
        args     => [$tf],
        settings => Fake::Settings2->new(
            Fake::Workspace2->new($work),
            Fake::Resource2->new(slots => $slots, job_slots => $job_slots),
        ),
    );
    my $ok  = eval { $cmd->run; 1 };
    my $err = $@;
    # Expect the spawn stub to die with EARLY_EXIT; anything else is
    # an unexpected failure and should be re-thrown so the test sees it.
    die $err unless !$ok && $err =~ /^EARLY_EXIT/;
}

subtest '-j 8 wires slots=8 max_per_job=1 into JobCount; TestFile unmodified' => sub {
    run_with_resource(8, 1);
    is(scalar @captured_jobcount, 1, 'one JobCount constructed');
    is($captured_jobcount[0]->{slots},       8, 'slots=8 from settings->resource->slots');
    is($captured_jobcount[0]->{max_per_job}, 1, 'max_per_job=1 from settings->resource->job_slots');
    ok(!exists $captured_testfiles[0]->{min_slots}, 'TestFile min_slots not overridden');
    ok(!exists $captured_testfiles[0]->{max_slots}, 'TestFile max_slots not overridden');
};

subtest '-j 16:8 wires slots=16 max_per_job=8' => sub {
    run_with_resource(16, 8);
    is($captured_jobcount[0]->{slots},       16, 'slots=16');
    is($captured_jobcount[0]->{max_per_job}, 8,  'max_per_job=8');
};

done_testing;
