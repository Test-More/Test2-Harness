use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;

use App::Yath2::Log;
use App::Yath2::Options::Concluder;

# Verifies the parent-process concluder dispatch contract:
#   * init_concluders builds the active set in deterministic order.
#   * ResetTerm is always last regardless of registration order.
#   * dispatch_concluders runs each in turn.
#   * A throwing concluder does not abort the chain.

{

    package T::Concluder::Recorder;
    use parent 'App::Yath2::Concluder';
    our @LOG;

    sub run {
        my $self = shift;
        push @LOG, ref($self);
        return;
    }
}
{

    package T::Concluder::Boom;
    use parent 'App::Yath2::Concluder';
    sub run { die "boom" }
}
{

    package T::Concluder::Recorder::A;
    our @ISA = ('T::Concluder::Recorder');
}
{

    package T::Concluder::Recorder::B;
    our @ISA = ('T::Concluder::Recorder');
}

# Mark these inline packages as loaded so init_concluders' require
# short-circuit picks them up instead of looking for them on disk.
$INC{'T/Concluder/Recorder.pm'}   = 1;
$INC{'T/Concluder/Boom.pm'}       = 1;
$INC{'T/Concluder/Recorder/A.pm'} = 1;
$INC{'T/Concluder/Recorder/B.pm'} = 1;

# A minimal settings stand-in that exposes the concluder group via the
# Getopt::Yath shape consumed by init_concluders. We mimic just the
# slice we need: check_group and the per-group accessor returning a
# small object with a classes hash.
{

    package T::FakeGroup;

    sub new {
        my ($class, %a) = @_;
        return bless {classes => $a{classes} // {}}, $class;
    }
    sub classes { $_[0]->{classes} }
}
{

    package T::FakeSettings;

    sub new {
        my ($class, %g) = @_;
        return bless {groups => \%g}, $class;
    }

    sub check_group {
        my ($self, $g) = @_;
        return exists $self->{groups}{$g} ? 1 : 0;
    }
    sub concluder { $_[0]->{groups}{concluder} }
}

sub _empty_log {
    my $dir = tempdir(CLEANUP => 1);
    return App::Yath2::Log->new(dir => $dir);
}

subtest 'init_concluders returns empty when group missing' => sub {
    my $log = _empty_log();
    my $cs  = App::Yath2::Options::Concluder->init_concluders(
        T::FakeSettings->new,
        log => $log,
    );
    is($cs, [], 'no concluders when concluder group missing');
};

subtest 'init_concluders empty hash returns empty list' => sub {
    my $log = _empty_log();
    my $s   = T::FakeSettings->new(
        concluder => T::FakeGroup->new(classes => {}),
    );
    my $cs = App::Yath2::Options::Concluder->init_concluders($s, log => $log);
    is($cs, [], 'empty classes -> no concluders');
};

subtest 'ResetTerm pinned last regardless of registration order' => sub {
    @T::Concluder::Recorder::LOG = ();

    # Register the real ResetTerm first and a recorder after to verify
    # ordering: even though ResetTerm registers first, it dispatches
    # last.
    my $log = _empty_log();
    my $s   = T::FakeSettings->new(
        concluder => T::FakeGroup->new(
            classes => {
                'App::Yath2::Concluder::ResetTerm' => [],
                'T::Concluder::Recorder::A'        => [],
                'T::Concluder::Recorder::B'        => [],
            }
        ),
    );

    my $cs = App::Yath2::Options::Concluder->init_concluders($s, log => $log);
    is(scalar(@$cs), 3, 'three concluders built');

    my @classes = map { ref($_) } @$cs;
    is(
        $classes[-1],
        'App::Yath2::Concluder::ResetTerm',
        'ResetTerm pinned last',
    );

    # Recorders run in alpha order (A before B).
    is(
        [grep { /^T::Concluder::Recorder/ } @classes],
        ['T::Concluder::Recorder::A', 'T::Concluder::Recorder::B'],
        'non-ResetTerm concluders sort by class name',
    );

    # Dispatch and verify only the recorders log (ResetTerm is a no-op
    # against the in-memory tied STDOUT in this harness; we just want
    # to see it gets called without blowing up).
    open my $fh, '>', \my $buf or die "scalar: $!";
    # Reach in and replace out_fh for ResetTerm so it does not try to
    # write to a real tty in the test harness.
    for my $c (@$cs) {
        $c->{out_fh} = $fh if ref($c) eq 'App::Yath2::Concluder::ResetTerm';
    }
    App::Yath2::Options::Concluder->dispatch_concluders($cs);

    is(
        \@T::Concluder::Recorder::LOG,
        ['T::Concluder::Recorder::A', 'T::Concluder::Recorder::B'],
        'recorders ran, in order, before ResetTerm',
    );
};

subtest 'throwing concluder does not abort the chain' => sub {
    @T::Concluder::Recorder::LOG = ();

    my $log = _empty_log();
    my $s   = T::FakeSettings->new(
        concluder => T::FakeGroup->new(
            classes => {
                'T::Concluder::Boom'        => [],
                'T::Concluder::Recorder::A' => [],
            }
        ),
    );

    my $cs = App::Yath2::Options::Concluder->init_concluders($s, log => $log);

    # Suppress the warning that the failure emits so the test output
    # stays clean.
    my $warn_buf = '';
    my $ran;
    {
        local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
        $ran = App::Yath2::Options::Concluder->dispatch_concluders($cs);
    }

    is($ran, 1, 'one concluder succeeded (recorder); boom failed');
    like($warn_buf, qr/Concluder T::Concluder::Boom failed/, 'failure surfaced as warning');
    is(
        \@T::Concluder::Recorder::LOG,
        ['T::Concluder::Recorder::A'],
        'recorder still ran after boom died',
    );
};

subtest 'Summary + ResetTerm defaults produce summary banner' => sub {
    # Build a real log + the real default concluder set, run it end to
    # end, and verify Summary actually produced output. Use a tempdir
    # so the test does not depend on the cwd / global state.
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs/1/jobs/j1/0");

    open my $sp, '>', "$dir/runs/1/jobs/j1/0/spec.jsonl" or die "spec: $!";
    close $sp;

    open my $js, '>', "$dir/runs/1/jobs/j1/0/.sealed" or die "job seal: $!";
    print $js encode_json({sealed_at => 200, pass => 1});
    close $js;

    open my $rs, '>', "$dir/runs/1/.sealed" or die "run seal: $!";
    print $rs encode_json({sealed_at => 300, pass => 1, exit => 0});
    close $rs;

    my $log = App::Yath2::Log->new(dir => $dir);
    my $s   = T::FakeSettings->new(
        concluder => T::FakeGroup->new(
            classes => {
                'App::Yath2::Concluder::Summary'   => [],
                'App::Yath2::Concluder::ResetTerm' => [],
            }
        ),
    );

    my $cs = App::Yath2::Options::Concluder->init_concluders($s, log => $log);

    # Capture the Summary concluder's output.
    open my $fh, '>', \my $buf or die "scalar: $!";
    for my $c (@$cs) {
        $c->{out_fh} = $fh;
    }

    App::Yath2::Options::Concluder->dispatch_concluders($cs);

    like($buf, qr/Run 1: 1 job, 1 passed, 0 failed, 0 abandoned/, 'summary banner appears');
    like($buf, qr/Result: PASSED/,                                'verdict appears');
};

done_testing;
