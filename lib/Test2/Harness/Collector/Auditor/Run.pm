package Test2::Harness::Collector::Auditor::Run;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use List::Util qw/min max sum0/;

use parent 'Test2::Harness::Collector::Auditor';
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

    $self->SUPER::init();

    $self->{+LAUNCHES} = 0;
    $self->{+ASSERTS}  = 0;

    $self->{+TIMES} //= [0, 0, 0, 0];

    $self->{+JOBS} = {};
}

sub has_plan { undef }
sub has_exit { undef }

sub pass { !$_[0]->fail }

sub fail {
    my $self = shift;

    my $final = $self->final_data;

    my $count = @{$final->{failed} // []};

    return $count;
}

sub exit_value {
    my $self = shift;

    my $count = $self->fail;

    $count = 255 if $count > 255;
    return $count;
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
    my @out;

    push @out => $self->_audit($_) for @_;

    return @out;
}

sub _audit {
    my $self = shift;
    my ($e) = @_;

    return undef unless defined $e;

    delete $self->{+FINAL_DATA};
    delete $self->{+SUMMARY};

    $self->{+START} = $self->{+START} ? min($self->{+START}, $e->{stamp}) : $e->{stamp};
    $self->{+STOP}  = $self->{+STOP}  ? max($self->{+STOP}, $e->{stamp})  : $e->{stamp};

    my $f = $e->{facet_data};
    my $job_id = $f->{harness}->{job_id} or return $e;
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

    return $e;
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
