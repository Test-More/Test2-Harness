package TAP::Harness::Yath;
use strict;
use warnings;
use Carp::Always;

# $ENV{HARNESS_SUBCLASS}

{
    package TAP::Harness::Yath::Aggregator;

    use Test2::Harness::Util::HashBase qw{
        total
        passed
        failed
    };

    sub has_errors { $_[0]->{+FAILED} }
}

our $SUMMARY;

use App::Yath::Script;
use Test2::Harness::Util::HashBase qw{
    color
    ignore_exit
    jobs
    lib
    switches
    timer
    verbosity
};

sub runtests {
    my $self = shift;
    my (@tests) = @_;

    my @env_args = $ENV{TAP_HARNESS_YATH_ARGS} ? split(/\s*,\s*/, $ENV{TAP_HARNESS_YATH_ARGS}) : ();

    my @args = (
        'test',
        $self->{+COLOR} ? '--color' : (),
        '--jobs=' . ($self->{+JOBS} // 1),
        '-v=' . ($self->{+VERBOSITY} // 0),
        (map { "-I$_" } @{$self->{+LIB} // []}),
        (map { "-S=$_" } @{$self->{+SWITCHES} // []}),
        '--renderer=Default',
        '--renderer=TAPHarness',
        @env_args,
        @tests,
    );

    my $got = App::Yath::Script::run(__FILE__, \@args);

    my $seen = $SUMMARY->{'tests_seen'} //= 0;
    my $failed = $SUMMARY->{'failed'} //= $got;

    my $out = TAP::Harness::Yath::Aggregator->new(
        total => $seen,
        failed => $failed,
        passed => $seen - $failed,
    );

    use Data::Dumper;
    print STDERR Dumper($out);

    return $out;
}

1;

__END__
