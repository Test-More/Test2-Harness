package Test2::Harness::UI::Sweeper;
use strict;
use warnings;

our $VERSION = '0.000104';

use Test2::Harness::UI::Util::HashBase qw{
    <config
    <interval
};

my @TABLES = qw{
    api_keys coverage coverage_manager email email_verification_codes events
    job_fields jobs log_files permissions primary_email projects run_fields
    runs session_hosts sessions source_files source_subs test_files users
};

sub sweep {
    my $self = shift;
    my %params = @_;

    $params{runs}       //= 1;
    $params{jobs}       //= 1;
    $params{coverage}   //= 1;
    $params{events}     //= 1;
    $params{subtests}   //= 1;
    $params{run_fields} //= 1;
    $params{job_fields} //= 1;

    # Cannot remove jobs if we keep events
    $params{jobs} = 0 unless $params{events} && $params{subtests} && $params{job_fields};

    # Cannot delete runs if we save jobs or coverage
    $params{runs} = 0 unless $params{jobs} && $params{coverage} && $params{run_fields};

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

            if ($params{job_fields}) {
                $job->job_fields->delete;
            }

            $job->delete if $params{jobs};
        }

        if ($params{run_fields}) {
            $run->run_fields->delete;
        }

        if ($params{coverage}) {
            $run->coverages->delete;
            $run->update({has_coverage => 0}) unless $params{runs};
        }
        $run->delete if $params{runs};
    }

    if ($db_type =~ m/mysql/i) {
        my $dbh = $self->config->schema->storage->dbh;
        $dbh->do('ANALYZE TABLE ' . join ', ' => @TABLES);
    }

    return \%counts;
}

1;


