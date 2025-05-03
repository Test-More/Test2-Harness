package Test2::Harness::Runner::Preloading;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util qw/parse_exit mod2file/;
use Test2::Harness::Util::JSON qw/encode_json/;
use Test2::Harness::IPC::Util qw/pid_is_running/;

use Test2::Harness::Preload();
use Test2::Harness::TestSettings;
use Test2::Harness::Runner::Preloading::Stage;

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase qw{
    +stages
    <preloads
    <preload_early
    default_stage
    <preload_retry_delay
    <reloader
    <reload_in_place
    <restrict_reload
    +blacklist
};

sub init {
    my $self = shift;

    die "The PRELOAD runner is not usable on Windows.\n" if IS_WIN32;

    $self->SUPER::init();

    $self->{+STAGES} = undef;

    $self->{+PRELOAD_RETRY_DELAY} //= 5;

    $self->{+BLACKLIST} //= {};
}

sub blacklist {
    my $self = shift;

    for my $mod (@_) {
        $self->{+BLACKLIST}->{$mod}++;
    }

    return $self->{+BLACKLIST} // {};
}

sub process_list {
    my $self = shift;
    my $stages = $self->stages or return;

    my @out;

    for my $stage_name (keys %$stages) {
        next if $stage_name eq 'NONE';
        my $stage = $stages->{$stage_name};
        my $ready = $stage->{ready} or next;
        push @out => {pid => $ready->{pid} // 'PENDING', type => 'stage', name => $stage_name, stamp => $ready->{stamp}};
    }

    return @out;
}

sub overall_status {
    my $self = shift;

    my $stages = $self->stages or return;

    my @rows;

    for my $stage_name (sort { $a cmp $b } keys %$stages) {
        next if $stage_name eq 'NONE';

        my $stage  = $stages->{$stage_name};
        my $ready  = $stage->{ready};
        my $err    = $stage->{error};

        my $status = $ready ? 'UP' : 'DOWN';
        my $pid    = $ready ? $ready->{pid}   // 'PENDING' : '';
        my $stamp  = $ready ? $ready->{stamp} // undef     : undef;
        my $age = $stamp ? time - $stamp : undef;

        push @rows => [$age, $pid, $stage_name, $status, $err];
    }

    return {
        title  => "Runner Status",
        tables => [
            {
                title    => "Stages",
                collapse => 1,
                format   => [qw/duration/, undef, undef,   undef,    undef],
                header   => ['age',        'pid', 'stage', 'status', 'error'],
                rows     => \@rows,
            },
        ],
    };
}


sub ready { $_[0]->{+STAGES} ? 1 : 0 }

sub set_stages {
    my $self = shift;
    my ($data) = @_;

    $data->{NONE}->{ready} = {pid => undef, con => undef};
    $data->{NONE}->{can_run} //= [];

    for my $stage_name (keys %$data) {
        my $stage = $data->{$stage_name};
        next unless $stage->{default};
        $self->set_default_stage($stage_name);
    }

    $self->{+STAGES} = $data;
}

sub stages {
    my $self = shift;

    return $self->{+STAGES} // confess "No stage data";
}

sub set_stage_up {
    my $self = shift;
    my ($stage, $pid, $con) = @_;

    my $stage_data = $self->stages->{$stage} // die "Invalid stage '$stage'";
    $stage_data->{ready} = {pid => $pid, con => $con, stamp => time};
    delete $stage_data->{error};

    return $pid;
}

sub set_stage_down {
    my $self = shift;
    my ($stage, $pid, $err) = @_;

    my $stage_data = $self->stages->{$stage} // die "Invalid stage '$stage'";

    if(my $ready = $stage_data->{ready}) {
        if ($pid && $ready->{pid}) {
            # It is possible we got the 'down' after a new 'up'
            if ($ready->{pid} == $pid) {
                delete $stage_data->{ready};
            }
        }
        else {
            delete $stage_data->{ready};
        }
    }

    if ($err) {
        $stage_data->{error} = $err;
    }

    return 1;
}

sub stage_sets {
    my $self = shift;

    my $stages = $self->stages;

    my %sets;

    for my $stage (keys %$stages) {
        my $sdata = $stages->{$stage};
        my $ready = $sdata->{ready} or next;
        if (ref($ready)) {
            next unless $ready->{con};
            next unless $ready->{pid};
        }

        $sets{$stage} = $stage;
        $sets{$_} //= $stage for @{$sdata->{can_run} // []};
    }

    return [ map { [$_ => $sets{$_}] } keys %sets ];
}

sub DESTROY {
    my $self = shift;

    $self->terminate unless $self->{+TERMINATED};

    kill('TERM', grep { $_ && pid_is_running($_) } map { $_->{ready}->{pid} // () } values %{$self->stages});
}

sub reload {
    my $self = shift;
    kill('HUP', grep { $_ && pid_is_running($_) } map { $_->{ready}->{pid} // () } values %{$self->stages});
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;
    $reason //= 1;

    $self->SUPER::terminate(@_);
    for my $stage (values %{$self->stages}) {
        next unless $stage->{ready} && $stage->{ready}->{con};
        $stage->{ready}->{con}->send_message({terminate => $reason});
    }
}

sub kill {
    my $self = shift;
    $self->terminate('kill');
}

sub job_stage {
    my $self = shift;
    my ($job, $stage_request) = @_;

    my $stages = $self->stages;

    return 'NONE' unless $self->{+PRELOADS} && @{$self->{+PRELOADS}};

    for my $s ($stage_request, $self->default_stage, 'BASE') {
        next unless $s;
        next unless $stages->{$s};
        return $s;
    }

    confess "No valid stages!";
}

sub start {
    my $self = shift;
    my ($scheduler, $ipc) = @_;

    my $ts = $self->{+TEST_SETTINGS};

    my $preloads = $self->{+PRELOADS} or return;
    return unless @$preloads;

    $self->start_base_stage($scheduler, $ipc);
}

sub start_base_stage {
    my $self = shift;
    my ($scheduler, $ipc, $last_launch, $last_exit, $exit_code) = @_;

    print "Launching 'BASE' stage.\n";

    my $pid = Test2::Harness::Runner::Preloading::Stage->launch(
        name            => 'BASE',
        test_settings   => $self->{+TEST_SETTINGS},
        ipc_info        => $ipc->[0]->callback,
        preload_early   => $self->preload_early,
        preloads        => $self->preloads,
        retry_delay     => $self->{+PRELOAD_RETRY_DELAY},
        last_launch     => $last_launch,
        last_exit       => $last_exit,
        last_exit_code  => $exit_code,
        reloader        => $self->reloader,
        reload_in_place => $self->reload_in_place,
        restrict_reload => $self->{+RESTRICT_RELOAD},
        root_pid        => $$,
        is_daemon       => $self->{+IS_DAEMON},
    );

    my $launched = time;
    $scheduler->register_child(
        $pid,
        stage => 'BASE',
        sub {
            my %params = @_;

            my $exit      = $params{exit};
            my $scheduler = $params{scheduler};

            my $x = parse_exit($exit);
            print "Stage 'BASE' exited (sig: $x->{sig}, code: $x->{err}).\n";

            return if $scheduler->terminated || $scheduler->runner->terminated;

            if ($self->is_daemon) {
                $scheduler->runner->start_base_stage($scheduler, $ipc, $launched, time, $x->{err});
            }
            else {
                $self->terminate('Stage Ended');
                $scheduler->terminate('Stage Ended');
            }
        },
    );
}

sub launch_job {
    my $self = shift;
    my ($stage, $run, $job, $env) = @_;

    my %job_launch_data = $self->job_launch_data($run, $job, $env);
    my $ts = $job_launch_data{test_settings};

    my $can_fork = 1;
    $can_fork &&= $stage ne 'NONE';
    $can_fork &&= $ts->use_fork;
    $can_fork &&= $ts->use_preload;

    return $self->SUPER::launch_job('NONE', $run, $job) unless $can_fork;

    my $stage_data = $self->stages->{$stage} or confess "Invalid stage: '$stage'";

    my $res = $stage_data->{ready}->{con}->send_and_get(launch_job => \%job_launch_data);
    return 1 if $res->success;
}

sub spawn {
    my $self = shift;
    my ($spawn) = @_;

    my $stage = $spawn->{stage} // 'BASE';
    my $stage_data = $self->stages->{$stage} or die "Invalid stage: '$stage'.\n";

    die "Stage '$stage' is not ready.\n" unless $stage_data->{ready} && $stage_data->{ready}->{con};

    my $res = $stage_data->{ready}->{con}->send_and_get(spawn => $spawn);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preloading - FIXME

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

