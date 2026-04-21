package App::Yath2::Command::status;
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

# `yath status` prints a summary of the attached daemon's state:
# service info, queue, running jobs, resources.
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
        print STDERR "yath status: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath status: cannot attach to daemon: $@";
        return 2;
    }

    my $st = eval { $spawn->status };
    unless (ref($st) eq 'HASH') {
        print STDERR "yath status: no status response (daemon dead?): $@";
        return 1;
    }

    my $svc = $st->{service} // {};
    print "Daemon:\n";
    print "  name:    ", ($svc->{name}    // '?'), "\n";
    print "  pid:     ", ($svc->{pid}     // '?'), "\n";
    print "  state:   ", ($svc->{state}   // '?'), "\n";
    print "  workdir: ", ($svc->{workdir} // '?'), "\n";

    my $queue = $st->{queue} // [];
    print "\nRuns:\n";
    if (@$queue) {
        for my $run (@$queue) {
            print sprintf(
                "  run=%s  pending=%d  running=%d  done=%d  pass=%d  fail=%d\n",
                $run->{run_id},
                scalar(@{$run->{pending} // []}),
                scalar(@{$run->{running} // []}),
                scalar(@{$run->{done}    // []}),
                $run->{pass_count} // 0,
                $run->{fail_count} // 0,
            );
        }
    }
    else {
        print "  (none)\n";
    }

    my $running = $st->{running} // [];
    print "\nRunning jobs:\n";
    if (@$running) {
        for my $job (@$running) {
            print sprintf(
                "  %s  pid=%s  run=%s  job=%s\n",
                $job->{test_file} // '?',
                $job->{pid}       // '?',
                $job->{run_id}    // '?',
                $job->{job_id}    // '?',
            );
        }
    }
    else {
        print "  (none)\n";
    }

    my $resources = $st->{resources} // [];
    if (@$resources) {
        print "\nResources:\n";
        for my $res (@$resources) {
            next unless ref($res) eq 'HASH';
            print "  ", ($res->{resource} // ref($res) // '?'), "\n";
        }
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::status - Print a summary of a running daemon's state.

=head1 DESCRIPTION

Attaches to a running daemon (discovery via
L<App::Yath2::Daemon/attach>) and prints a human-readable summary of
the daemon's service state, queued runs, running jobs, and global
resources.

=cut
