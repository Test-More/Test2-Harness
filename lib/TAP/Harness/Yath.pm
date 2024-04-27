package TAP::Harness::Yath;
use strict;
use warnings;

# $ENV{HARNESS_SUBCLASS}

{
    package TAP::Harness::Yath::Aggregator;

    use Test2::Harness::Util::HashBase qw{
        files_total
        files_failed
        files_passed

        asserts_total
        asserts_passed
        asserts_failed
    };

    sub has_errors { $_[0]->{+FILES_FAILED} || $_[0]->{+ASSERTS_FAILED} }

    sub total  { $_[0]->{+ASSERTS_TOTAL} }
    sub failed { $_[0]->{+ASSERTS_FAILED} }
    sub passed { $_[0]->{+ASSERTS_PASSED} }

    sub total_files  { $_[0]->{+FILES_TOTAL} }
    sub failed_files { $_[0]->{+FILES_FAILED} }
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

    my $files_total  = $SUMMARY->{'tests_seen'} //= 0;
    my $files_failed = $SUMMARY->{'failed'}     //= $got;
    my $files_passed = $files_total - $files_failed;

    my $asserts_total  = $SUMMARY->{'asserts_seen'}   // 0;
    my $asserts_passed = $SUMMARY->{'asserts_passed'} // 0;
    my $asserts_failed = $SUMMARY->{'asserts_failed'} // 0;

    my $out = TAP::Harness::Yath::Aggregator->new(
        files_total    => $files_total,
        files_failed   => $files_failed,
        files_passed   => $files_passed,

        asserts_total  => $asserts_total,
        asserts_passed => $asserts_passed,
        asserts_failed => $asserts_failed,
    );

    return $out;
}

1;

__END__
