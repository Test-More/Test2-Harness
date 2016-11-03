use Test2::Bundle::Extended -target => 'Test2::Harness::Renderer::DataDumper';

use File::Spec;
use File::Temp qw/tempdir/;
use Test2::Harness::Fact;
use Test2::Harness::Job;
use Test2::Harness::Result;

my $tempdir = tempdir(CLEANUP => 1);
local $ENV{TEST2_DUMP_DIR} = $tempdir;
my $renderer = Test2::Harness::Renderer::DataDumper->new;

my $test1_t = 'test1.t';
my $test2_t = 'path/to/test2.t';

my @facts = map { Test2::Harness::Fact->new(%{$_}) } (
    {
        start  => 1,
        nested => 0,
    },
    {
        sets_plan => [42, undef, undef],
        nested    => 0,
    },
    {
        causes_fail => 1,
        diagnostics => 'Something broke',
        nested      => 0,
    },
);
my %test_data = (
    1 => {
        job   => Test2::Harness::Job->new(id => 1, file => $test1_t),
        facts => [@facts],
    },
    2 => {
        job   => Test2::Harness::Job->new(id => 2, file => $test2_t),
        facts => [@facts],
    },
);

for my $id (sort keys %test_data) {
    my $job = $test_data{$id}{job};

    for my $fact (@{$test_data{$id}{facts}}) {
        $renderer->process($job, $fact);
    }

    my $result = Test2::Harness::Result->new(
        file => $job->file,
        job  => $job->id,
        name => $job->file,
    );
    $result->add_facts(@{$test_data{$id}{facts}});

    my $fact = Test2::Harness::Fact->new(
        nested => -1,
        result => $result,
    );
    $renderer->process($job, $fact);

    push @{$test_data{$id}{facts}}, $fact;
}

my $test1_dump = File::Spec->catfile($tempdir, $test1_t . '.dd');
my $test2_dump = File::Spec->catfile($tempdir, $test2_t . '.dd');
ok(-f $test1_dump, "json file for test1.t exists at $test1_dump");
ok(-f $test2_dump, "json file for test2.t exists at $test2_dump");

is(
    decode($test1_dump),
    $test_data{1}{facts},
    'dump in test1.dd contains expected facts'
);

is(
    decode($test2_dump),
    $test_data{2}{facts},
    'dump in test2.dd contains expected facts'
);

done_testing;

sub decode {
    my $file = shift;

    open my $fh, '<', $file or die "Cannot read $file: $!";
    my $dump = do { local $/; <$fh> };
    close $fh;

    our $VAR1;
    local $VAR1;
    local $@;

    eval $dump;
    die $@ if $@;

    return $VAR1;
}
