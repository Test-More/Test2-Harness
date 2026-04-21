package App::Yath2::Command::ps;
use strict;
use warnings;

our $VERSION = '2.000011';

use App::Yath2::Daemon;

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath ps`: list every process the daemon tracks (the harness
# itself, run services, resource services, running test-job
# collectors). Source: list_processes IPC request.
sub run {
    my $self = shift;

    my %opts;
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath ps: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath ps: cannot attach to daemon: $@";
        return 2;
    }

    my $res = eval { $spawn->list_processes };
    unless (ref($res) eq 'HASH' && $res->{ok}) {
        print STDERR "yath ps: list_processes failed: ",
            (ref($res) eq 'HASH' ? ($res->{error} // '(no error)') : ($@ // '(no response)')),
            "\n";
        return 1;
    }

    printf "%-8s  %-10s  %-10s  %s\n", qw/PID TYPE ROLE NAME/;
    for my $proc (@{$res->{processes} // []}) {
        my $name = $proc->{name};
        if (!defined $name || !length $name) {
            $name = $proc->{test_file} // $proc->{job_id} // '';
        }
        printf "%-8s  %-10s  %-10s  %s\n",
            ($proc->{pid}  // '?'),
            ($proc->{type} // '?'),
            ($proc->{role} // '?'),
            $name;
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::ps - List processes the daemon tracks.

=head1 DESCRIPTION

Attaches to a running daemon and prints one row per tracked process:
the harness service, every run service, every resource service,
every active test-job collector.

=cut
