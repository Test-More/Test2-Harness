package Test2::Harness::Run;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness::TestSettings;
use Test2::Harness::IPC::Protocol;

use Test2::Harness::Util qw/mod2file/;
use Test2::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000005';

my @NO_JSON;
BEGIN {
    @NO_JSON = qw{
        ipc
        connect
        send_event_cb
    };

    sub no_json { @NO_JSON }
}

use Test2::Harness::Util::HashBase(
    # From Options::Run
    qw{
        <links
        <test_args
        <input
        <input_file
        <dbi_profiling
        <author_testing
        <stream
        <fields
        <run_id
        <event_uuids
        <mem_usage
        <retry
        <retry_isolated
        <abort_on_bail
        <nytprof
        <interactive
    },

    qw{
        <interactive_pid
        instance_ipc
        <aggregator_ipc
        <aggregator_use_io
        <jobs
        <job_lookup
        <test_settings
        <settings
    },

    (map { "+$_" } @NO_JSON),
);

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute" unless $self->{+RUN_ID};

    $self->{+INTERACTIVE_PID} //= $$ if $self->{+INTERACTIVE};

    my $ts = $self->{+TEST_SETTINGS} or croak "'test_settings' is a required attribute";
    unless (blessed($ts)) {
        my $class = delete $ts->{class} // 'Test2::Harness::TestSettings';
        $self->{+TEST_SETTINGS} = $class->new(%$ts);
    }

    if (my $jobs = $self->{+JOBS}) {
        my (@jobs, %jobs);
        for my $job (@$jobs) {
            my $class = $job->{job_class} // 'Test2::Harness::Run::Job';
            require(mod2file($class));
            my $jo = $class->new(%$job);
            push @jobs => $jo;
            $jobs{$jo->job_id} = $jo;
        }
        $self->{+JOBS} = \@jobs;
        $self->{+JOB_LOOKUP} = \%jobs;
    }

    croak "'aggregator_ipc' or 'aggregator_use_io' must be specified" unless $self->{+AGGREGATOR_IPC} || $self->{+AGGREGATOR_USE_IO};
}

sub set_ipc { $_[0]->{+IPC} = $_[1] }
sub ipc {
    my $self = shift;
    return $self->{+IPC} if $self->{+IPC};

    my $agg_ipc = $self->{+AGGREGATOR_IPC} // croak "This run does not use standard IPC";
    return $self->{+IPC} = Test2::Harness::IPC::Protocol->new(protocol => $agg_ipc->{protocol});
}

sub set_connect { $_[0]->{+CONNECT} = $_[1] }
sub connect {
    my $self = shift;
    return $self->{+CONNECT} if $self->{+CONNECT};

    my $agg_ipc = $self->{+AGGREGATOR_IPC} // croak "This run does not use standard IPC";
    return $self->{+CONNECT} = $self->ipc->connect(@{$agg_ipc->{connect}});
}

sub send_initial_events {
    my $self = shift;

    my $stamp = time;

    $self->send_event(stamp => $stamp, facet_data => {harness_run => $self->data_no_jobs});

    for my $job (@{$self->jobs}) {
        $self->send_event(
            job_id  => $job->job_id,
            job_try => $job->try,
            stamp   => $stamp,

            facet_data => {
                harness_job_queued => {
                    file     => $job->test_file->file,
                    rel_file => $job->test_file->relative,
                    job_id   => $job->job_id,
                    stamp    => $stamp,
                }
            },
        );
    }
}

sub send_event_cb {
    my $self = shift;

    return unless -p STDOUT;

    croak "This run does not use an STDIO pipe" unless $self->{+AGGREGATOR_USE_IO};

    require Test2::Harness::Collector::Child;
    $self->{+SEND_EVENT_CB} //= Test2::Harness::Collector::Child->send_event();
}

sub send_event {
    my $self  = shift;
    my $event = @_ == 1 ? shift : {@_};

    $event->{stamp}    //= time;
    $event->{event_id} //= gen_uuid;
    $event->{run_id}   //= $self->run_id;
    $event->{job_id}   //= 0;
    $event->{job_try}  //= 0;

    $event = Test2::Harness::Event->new($event)
        unless blessed($event);

    if ($self->{+AGGREGATOR_IPC}) {
        my $con = $self->connect;
        $con->send_message($event);
    }
    elsif ($self->{+AGGREGATOR_USE_IO}) {
        $self->send_event_cb->($event);
    }
    else {
        confess "Could not send event";
    }
}

sub data_no_jobs {
    my $self = shift;

    my %data = %$self;
    delete $data{$_} for $self->no_json, qw/jobs job_lookup/;

    return \%data;
}

sub TO_JSON {
    my $self = shift;

    my %data = %$self;
    delete $data{$_} for $self->no_json;

    return \%data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - FIXME

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

