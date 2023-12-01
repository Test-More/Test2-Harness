package Test2::Harness::Run::Auditor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use List::Util qw/min max sum0/;

use Test2::Harness::Util::HashBase qw{
    <jobs
    <launches
    <asserts
    <start
    <stop

    <times

    +final_data
    +summary
};

sub init {
    my $self = shift;

    $self->{+LAUNCHES} = 0;
    $self->{+ASSERTS}  = 0;

    $self->{+TIMES} //= [0, 0, 0, 0];

    $self->{+JOBS} = {};
}

sub subtest_name {
    my $self = shift;
    my ($f) = @_;
    return $f->{assert}->{details} // ($f->{trace}->{frame}->[1] . ' line ' . $f->{trace}->{frame}->[2]);
}

sub list_nested_subtests {
    my $self = shift;
    my ($f) = @_;

    my $name = $self->subtest_name($f);
    my @children = map { "$name -> $_" } map { $self->list_nested_subtests($_) } grep { $_->{assert} && $_->{parent} } @{$f->{parent}->{children} // []};

    return ($name, @children);
}

sub audit {
    my $self = shift;
    my ($e) = @_;

    $self->{+START} = $self->{+START} ? min($self->{+START}, $e->stamp) : $e->stamp;
    $self->{+STOP}  = $self->{+STOP}  ? max($self->{+STOP}, $e->stamp)  : $e->stamp;

    my $f = $e->facet_data;
    my $job_id = $f->{harness}->{job_id} or return;
    my $job_try = $f->{harness}->{job_try} // 0;

    my $tries = $self->{+JOBS}->{$job_id} //= [];
    my $job   = $tries->[$job_try]        //= {};

    if ($f->{assert}) {
        $self->{+ASSERTS}++;
    }

    if ($f->{parent} && !$f->{assert}->{pass}) {
        push @{$job->{failed_subtests} //= []} => $self->list_nested_subtests($f);
    }

    if (my $j = $f->{harness_job}) {
        my $file = $j->{file};
        $job->{file} = $file;
    }

    if ($f->{harness_job_launch}) {
        $job->{launched}++;
        $self->{+LAUNCHES}++;
    }

    if (my $end = $f->{harness_job_end}) {
        $job->{end}++;
        $job->{result} = $end->{fail} ? 0 : 1;
    }

    if (my $x = $f->{harness_job_exit}) {
        $job->{exit} = $x->{exit};

        if (my $times = $x->{times}) {
            for my $i (0 .. 3) {
                $self->{+TIMES}->[$i] += $times->[$i];
            }
        }
    }

    if (my $c = $f->{control}) {
        if ($c->{halt}) {
            $job->{halt} = $c->{details} || 'halt';
        }
    }
}

sub exit_value {
    my $self = shift;

    my $final = $self->final_data;

    my $count = @{$final->{failed} // []};

    $count = 255 if $count > 255;
    return $count;
}

sub final_data {
    my $self = shift;

    return $self->{+FINAL_DATA} if $self->{+FINAL_DATA};

    my $jobs = $self->{+JOBS};

    my $out = {};

    my $passing = 1;
    for my $job_id (keys %$jobs) {
        my $tries = $jobs->{$job_id};
        my $job = $tries->[-1];

        if ($job->{halt}) {
            $passing = 0;
            push @{$out->{halted}} => [$job_id, $job->{file}, $job->{halt}];
        }

        my $count = @$tries;

        if ($count < 1) {
            $passing = 0;
            push @{$out->{unseen}} => [$job_id, $job->{file}];
            next;
        }

        my $pass = $job->{result};

        if ($count > 1) {
            push @{$out->{retried}} => [$job_id, $count, $job->{file}, $pass ? 'YES' : 'NO'];
        }

        if (!$pass) {
            $passing = 0;
            push @{$out->{failed}} => [$job_id, $job->{file}, $job->{failed_subtests} ? $job->{failed_subtests} : ()];
        }
    }

    $out->{pass} = $passing;

    return $self->{+FINAL_DATA} = $out;
}

sub summary {
    my $self = shift;

    return $self->{+SUMMARY} if $self->{+SUMMARY};

    my $final_data = $self->final_data;

    my $times = $self->{+TIMES};
    my $wall = ($self->{+STOP} // 0) - ($self->{+START} // 0);
    my $cpu = sum0(@$times);

    return $self->{+SUMMARY} = {
        pass         => $self->{+ASSERTS} ? $final_data->{pass} : 0,
        cpu_usage    => $wall ? int($cpu / $wall * 100) : 0,
        failures     => (0 + @{$final_data->{failed} // []}),
        tests_seen   => $self->{+LAUNCHES},
        asserts_seen => $self->{+ASSERTS},

        time_data => {
            start   => $self->{+START},
            stop    => $self->{+STOP},
            wall    => $wall,
            user    => $times->[0],
            system  => $times->[1],
            cuser   => $times->[2],
            csystem => $times->[3],
            cpu     => $cpu,
        },
    };
}

1;

__END__

sub render_summary {
    my $self = shift;
    my ($summary) = @_;

    my $pass         = $summary->{pass};
    my $time_data    = $summary->{time_data};
    my $cpu_usage    = $summary->{cpu_usage};
    my $failures     = $summary->{failures};
    my $tests_seen   = $summary->{tests_seen};
    my $asserts_seen = $summary->{asserts_seen};

    return if $self->quiet > 1;

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $tests_seen",
        "Assertion Count: $asserts_seen",
        $time_data
        ? (
            sprintf("      Wall Time: %.2f seconds",                                                       $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%",                                                               $cpu_usage),
            )
        : (),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->color && USE_COLOR) {
        require Term::ANSIColor;
        my $color = $pass ? Term::ANSIColor::color('bold bright_green') : Term::ANSIColor::color('bold bright_red');
        my $reset = Term::ANSIColor::color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}






    {
        # Was the test run a success, or were there failures?
        pass => $BOOL,

        # What tests failed?
        failed => [
            [
                $job_id,    # Job id of the job that failed
                $file,      # Test filename
            ],
            ...
        ],

        # What tests had to be retried, and did they eventually pass?
        retried => [
            [
                $job_id,            # Job id of the job that was retied
                $tries,             # Number of tries attempted
                $file,              # Test filename
                $eventually_passed, # 'YES' if it eventually passed, 'NO' if no try ever passed.
            ],
            ...
        ],

        # What tests sent a halt event (such as bail-out, or skip the rest)
        halted => [
            [
                $job_id,    # Job id of the test
                $file,      # Test filename
                $halt,      # Halt code
            ],
            ...
        ],

        # What tests were never run (maybe because of a bail-out, or an internal error)
        unseen => [
            [
                $job_id,    # Job id of the test
                $file,      # Test filename
            ],
            ...
        ],
    }

1;
