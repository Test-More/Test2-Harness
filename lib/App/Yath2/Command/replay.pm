package App::Yath2::Command::replay;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use Carp qw/croak/;

use App::Yath2::LogArchive();
use App::Yath2::Streamer::Static();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 0 }
sub group              { 'log parsing' }
sub summary            { 'Replay events from a log archive or directory' }

sub cli_args { "[--] LOG [RUN_ID ...]" }

sub description {
    return <<"    EOT";
Replays the event stream recorded in a completed yath log. LOG is either a
.yath archive file or a directory that looks like \$workdir/logs (i.e. carries
an artifacts.json manifest at the top level). RUN_IDs, if any, restrict the
replay to the listed runs; with none, every run stored in the archive is
replayed.

Each event is printed as one JSON object per line. Output matches what 'yath
test' prints live, so anything that consumes the live stream will also consume
a replay.

Exit code is 0 when every replayed run passed, non-zero otherwise (or when
the archive has no runs at all).
    EOT
}

sub run {
    my $self = shift;

    # Autoflush so each event lands on stdout as soon as it is
    # emitted. Matches the test command's behaviour.
    local $| = 1;
    STDERR->autoflush(1);

    my $args = $self->{+ARGS} // [];
    shift @$args if @$args && $args->[0] eq '--';

    my $log = shift @$args
        or die "Usage: yath replay LOG [RUN_ID ...]\n";

    die "Log source '$log' does not exist\n"
        unless -e $log;

    # Requested run ids: default to the full set the archive carries.
    my @requested = @$args;
    unless (@requested) {
        my $archive = App::Yath2::LogArchive->new(path => $log);
        @requested = $archive->runs;
        die "No runs found in '$log'\n" unless @requested;
    }

    my $streamer = App::Yath2::Streamer::Static->new(
        log    => $log,
        runs   => [@requested],
        global => 1,
    );

    my $fail_runs = 0;
    my %seen_end;
    $streamer->stream(
        callback => sub {
            my ($event) = @_;
            my $fd = $event->facet_data // {};
            if (my $end = $fd->{harness_run_end}) {
                my $rid = $end->{run_id} // $event->run_id;
                $seen_end{$rid} = 1 if defined $rid;
                $fail_runs++ unless $end->{pass};
            }
            print $event->as_json, "\n";
        },
        # Exit when we have seen a run_end for every requested run.
        exit_if => sub { keys(%seen_end) >= scalar(@requested) ? 1 : 0 },
    );

    # Any requested run that never produced a run_end counts as a
    # failure. The static replay cannot synthesise a terminal state
    # for a run that was not completed when the archive was taken.
    for my $rid (@requested) {
        next if $seen_end{$rid};
        print STDERR "replay: run '$rid' has no terminal state in archive\n";
        $fail_runs++;
    }

    return $fail_runs ? 1 : 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
