package Test2::Harness::UI::Sweeper;
use strict;
use warnings;

our $VERSION = '0.000075';

use Test2::Harness::UI::Util::HashBase qw{
    <config
    <interval
};

sub sweep {
    my $self = shift;
    my %params = @_;

    $params{runs}     //= 1;
    $params{jobs}     //= 1;
    $params{coverage} //= 1;
    $params{events}   //= 1;
    $params{subtests} //= 1;

    # Cannot remove jobs if we keep events
    $params{jobs} = 0 unless $params{events} && $params{subtests};

    # Cannot delete runs if we save jobs or coverage
    $params{runs} = 0 unless $params{jobs} && $params{coverage};

    my $db_type = $self->config->guess_db_driver;

    my $interval = $params{interval} || $self->{+INTERVAL};
    if ($db_type eq 'PostgreSQL') {
        $interval = "< NOW() - INTERVAL '$interval'";
    }
    elsif ($db_type =~ m/mysql/i) {
        $interval = "< NOW() - INTERVAL $interval";
    }
    else {
        die "Not sure how to format interval for '$db_type'";
    }

    my $runs = $self->config->schema->resultset('Run')->search(
        {
            pinned => 'false',
            added => \$interval,
        },
    );

    my %counts;
    while (my $run = $runs->next()) {
        $counts{runs}++;
        my $jobs = $run->jobs;

        if ($params{coverage} && $run->coverage_id) {
            my $coverage = $run->coverage;
            $run->update({coverage_id => undef});
            $coverage->delete;
        }

        while (my $job = $jobs->next()) {
            $counts{jobs}++;
            if ($params{events}) {
                if ($params{subtests}) {
                    $job->events->delete;
                }
                else {
                    $job->events->search({'-not' => {is_subtest => 1, nested => 0}})->delete;
                }
            }
            $job->delete if $params{jobs};
        }

        $run->delete if $params{runs};
    }

    return \%counts;
}

1;
