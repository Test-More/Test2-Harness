package App::Yath::Schema::Sweeper;
use strict;
use warnings;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    <config
    <interval
};

my @TABLES = qw{
    api_keys resources coverage coverage_manager email email_verification_codes
    events job_try_fields job_tries jobs log_files permissions primary_email
    projects run_fields runs session_hosts sessions source_files source_subs
    test_files users
};

sub sweep {
    my $self = shift;
    my %params = @_;

    $params{runs}            //= 1;
    $params{jobs}            //= 1;
    $params{job_tries}       //= 1;
    $params{coverage}        //= 1;
    $params{events}          //= 1;
    $params{resources}       //= 1;
    $params{reports}         //= 1;
    $params{subtests}        //= 1;
    $params{run_fields}      //= 1;
    $params{job_try_fields}  //= 1;
    $params{run_concurrency} //= $ENV{YATH_SWEEPER_RUN_CONCURRENCY} // 1;
    $params{job_concurrency} //= $ENV{YATH_SWEEPER_JOB_CONCURRENCY} // 1;
    $params{sweep_name}      //= $ENV{YATH_SWEEPER_NAME};

    # Cannot remove jobs if we keep events
    $params{job_tries} = 0 unless $params{events} && $params{subtests} && $params{job_try_fields};
    $params{jobs} = 0 unless $params{job_tries};

    # Cannot delete runs if we save jobs or coverage
    $params{runs} = 0 unless $params{jobs} && $params{coverage} && $params{run_fields} && $params{resources} && $params{reports};

    my $db_type = $self->config->guess_db_driver;

    my $interval = $params{interval} || $self->{+INTERVAL};
    if ($db_type eq 'PostgreSQL') {
        $interval = "< NOW() - INTERVAL '$interval'";
    }
    elsif ($db_type =~ m/(mysql|percona|mariadb)/i) {
        $interval = "< NOW() - INTERVAL $interval";
    }
    else {
        die "Not sure how to format interval for '$db_type'";
    }

    my @sweep;
    if (my $sweep_name = $params{sweep_name}) {
        my $subquery = $self->config->schema->resultset('Sweep')->search({
            name => $sweep_name,
        });

        push @sweep => (
            run_id => { '-not_in' => $subquery->get_column('run_id')->as_query }
        );
    }

    print "Finding runs ...\n";
    my $runs = $self->config->schema->resultset('Run')->search(
        {
            pinned => 'false',
            added => \$interval,
            @sweep,
        },
    );

    my $counter = 0;
    if ($params{run_concurrency} <= 1) {
        while (my $run = $runs->next()) {
            $self->sweep_run($run, %params, id => $counter++);
        }
    }
    else {
        require Parallel::Runner;
        my $runner = Parallel::Runner->new($params{run_concurrency});

        while (my $run = $runs->next()) {
            my $id = $counter++;
            $runner->run(sub { $self->sweep_run($run, %params, id => $id) });
        }

        $runner->finish;
    }


    if ($db_type =~ m/(mysql|mariadb|percona)/i) {
        my $dbh = $self->config->schema->storage->dbh;
        $dbh->do('ANALYZE TABLE ' . join ', ' => @TABLES);
    }
}

sub sweep_run {
    my $self = shift;
    my ($run, %params) = @_;

    local $0 = "$0 - $params{id}: " . $run->run_id;

    my $start = time;

    my $jobs = $run->jobs;

    my $counter = 0;
    if ($params{job_concurrency} <= 1) {
        while (my $job = $jobs->next()) {
            $counter++;
            $self->sweep_job($run, $job, %params);
        }
    }
    else {
        require Parallel::Runner;
        my $runner = Parallel::Runner->new($params{job_concurrency});

        while (my $job = $jobs->next()) {
            $counter++;
            $runner->run(sub { $self->sweep_job($run, $job, %params) });
        }

        $runner->finish;
    }

    if ($params{run_fields}) {
        $run->run_fields->delete;
    }

    if ($params{coverage}) {
        $run->coverage->delete;
        $run->update({has_coverage => 0}) unless $params{runs};
    }

    if ($params{resources}) {
        $run->resources->delete;
        $run->update({has_resources => 0}) unless $params{runs};
    }

    if ($params{runs}) {
        $run->reports->delete;
        $run->sweeps->delete;
        $run->delete;
    }
    elsif (my $sweep_name = $params{sweep_name}) {
        $self->config->schema->resultset('Sweep')->find_or_create({name => $sweep_name, run_id => $run->run_id});
    }

    print "[$$] ($params{id}) Run: " . $run->run_uuid . " took " . sprintf("%0.4f", time - $start) . " seconds to sweep $counter job(s).\n";
}

sub sweep_job {
    my $self = shift;
    my ($run, $job, %params) = @_;

    local $0 = "$0 > " . $job->job_uuid;

    my $start = time;

    my $tries = $job->job_tries;
    while (my $try = $tries->next()) {
        if ($params{events}) {
            if ($params{subtests}) {
                my $has_binary = $try->events->search({has_binary => 1});
                while (my $e = $has_binary->next()) {
                    $e->binaries->delete;
                    $e->delete;
                }

                $try->events->delete;
            }
            else {
                my $events = $try->events->search({'-not' => {is_subtest => 1, nested => 0}});
                while (my $e = $events->next()) {
                    $e->binaries->delete;
                    $e->delete;
                }
            }
        }

        if ($params{job_try_fields}) {
            $try->job_try_fields->delete;
        }

        if ($params{reports}) {
            $try->reports->delete;
        }

        if ($params{job_tries}) {
            $try->delete;
        }
    }

    if ($params{jobs}) {
        $job->delete;
    }

    return unless (time - $start) > 1;
    print "[$$] ($params{id}) Run: " . $run->run_uuid . " job " . $job->job_uuid . " took " . sprintf("%0.4f", time - $start) . " seconds\n";
}

1;


__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Sweeper - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

