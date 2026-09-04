package Test2::Harness::Stall::Report;
use strict;
use warnings;

our $VERSION = '1.000179';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness::Util qw/clean_path write_file_atomic/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::Util::HashBase qw{
    <workdir <run_id <report_dir
};

use constant BEGIN_MARKER => '--- YATH STALL REPORT BEGIN ---';
use constant END_MARKER   => '--- YATH STALL REPORT END ---';

sub init {
    my $self = shift;

    croak "You must specify a workdir" unless defined $self->{+WORKDIR};

    # Where yath was run from. Not the workdir: for a plain 'yath test' that is
    # a File::Temp directory removed when the run ends, and this bundle is the
    # artifact the whole feature exists to produce.
    $self->{+REPORT_DIR} //= File::Spec->curdir;

    return;
}

# What the run state looked like, taken from the replay rather than from any
# live harness object.
sub state_summary {
    my $self = shift;
    my ($state, $tasks) = @_;

    my %out = (
        running       => $state->running       // 0,
        total_started => $state->total_started // 0,
        queue_ended   => $state->queue_ended ? 1 : 0,
        halted_runs   => [sort keys %{$state->halted_runs // {}}],
        stages        => $state->stage_readiness // {},
    );

    $out{running_tasks} = [map { {job_id => $_->{job_id}, file => $_->{rel_file} // $_->{file}} } values %{$state->running_tasks // {}}];

    $out{pending_tasks} = [
        map { {
            job_id    => $_->{job_id},
            file      => $_->{rel_file} // $_->{file},
            category  => $_->{category},
            duration  => $_->{duration},
            stage     => $_->{stage},
            conflicts => $_->{conflicts} // [],
            shares    => $_->{shares}    // [],
        } } @$tasks
    ];

    return \%out;
}

sub headline {
    my $self = shift;
    my ($bundle) = @_;

    return sprintf(
        "yath: no test has started in %.0f seconds (%s threshold %s), with %d pending and %d running.",
        $bundle->{idle},    $bundle->{tier}, $bundle->{threshold},
        $bundle->{pending}, $bundle->{running},
    );
}

sub render {
    my $self = shift;
    my ($bundle) = @_;

    my $out = "\n" . BEGIN_MARKER . "\n";
    $out .= $self->headline($bundle) . "\n";
    $out .= "This may be benign: the scheduler can also be waiting on something legitimate.\n";
    $out .= "It never ends the run. Use --stall-report to change or disable this.\n\n";

    my $state = $bundle->{state_summary} // {};
    $out .= sprintf(
        "Pending: %d  Running: %d  Started so far: %d  Queue ended: %s\n",
        scalar(@{$state->{pending_tasks} // []}),
        $state->{running}       // 0,
        $state->{total_started} // 0,
        $state->{queue_ended} ? 'yes' : 'no',
    );

    my $stages = $state->{stages} // {};
    $out .= "Stages: " . join(', ', map { "$_=" . ($stages->{$_} ? $stages->{$_} : 'down') } sort keys %$stages) . "\n";

    $out .= $self->task_lines('Running', $state->{running_tasks});
    $out .= $self->task_lines('Pending', $state->{pending_tasks});

    for my $sample (@{$bundle->{samples} // []}) {
        $out .= sprintf("\nSample %d:\n", $sample->{round});
        for my $pid (sort { $a <=> $b } keys %{$sample->{procs} // {}}) {
            my $proc = $sample->{procs}->{$pid};
            next if $proc->{gone};
            $out .= sprintf(
                "  pid %-7s %-18s state=%-22s wchan=%-24s syscall=%s\n",
                $pid,
                $proc->{name}  // '?',
                $proc->{state} // '?',
                $proc->{wchan} // '?',
                defined($proc->{syscall}) ? $proc->{syscall} : 'unavailable (needs ptrace permission)',
            );
        }
    }

    my $traces = $bundle->{traces} // {};
    if (keys %$traces) {
        $out .= "\nStack traces:\n";
        $out .= $traces->{$_} . "\n" for sort keys %$traces;
    }
    else {
        $out .= "\nNo stack traces were produced. A process that cannot run Perl -- one in an\n";
        $out .= "uninterruptible syscall, or in XS that retries EINTR -- never runs the handler.\n";
    }

    $out .= "\nFull details: " . $self->json_file($bundle->{round}) . "\n";
    $out .= END_MARKER . "\n";

    return $out;
}

# The tests themselves, since which ones are stuck waiting is usually the first
# thing a reader wants. Bounded: a stalled run can have hundreds pending, and
# the full list is in the JSON.
sub task_lines {
    my $self = shift;
    my ($label, $tasks) = @_;

    $tasks //= [];
    return '' unless @$tasks;

    my $out = "\n$label (" . scalar(@$tasks) . "):\n";

    my $shown = 0;
    for my $task (@$tasks) {
        last if $shown++ >= 20;

        my @extra;
        push @extra => $task->{category}                                if $task->{category} && $task->{category} ne 'general';
        push @extra => 'conflicts: ' . join(',', @{$task->{conflicts}}) if @{$task->{conflicts} // []};
        push @extra => 'shares: ' . join(',', @{$task->{shares}})       if @{$task->{shares}    // []};

        $out .= sprintf("  %s%s\n", $task->{file} // $task->{job_id} // '?', @extra ? ' [' . join('; ', @extra) . ']' : '');
    }

    $out .= sprintf("  ... and %d more\n", scalar(@$tasks) - $shown) if @$tasks > $shown;

    return $out;
}

sub json_file {
    my $self = shift;
    my ($round) = @_;

    # The run id keeps bundles from different runs apart; the round keeps a
    # run's own reports from overwriting each other.
    my $name = join('-', 'yath-stall-report', $self->{+RUN_ID} // $$, $round // 1) . '.json';

    return clean_path(File::Spec->catfile($self->{+REPORT_DIR}, $name));
}

# The aux_logs name matters. The collector re-reads that directory on every
# poll, picks up files created mid-run, and tags anything ending -STDERR.log as
# debug output, so this reaches the yath UI with no new plumbing. error.log
# cannot be used: it is the runner's redirected STDERR, opened without append,
# so a second writer and the runner would overwrite each other.
sub aux_file {
    my $self = shift;

    my $dir = File::Spec->catdir($self->{+WORKDIR}, 'aux_logs');
    mkdir($dir);

    return File::Spec->catfile($dir, 'stall-STDERR.log');
}

sub emit {
    my $self = shift;
    my ($bundle) = @_;

    my $text = $self->render($bundle);
    my $json = encode_json($bundle);

    # The terminal and the CI log get the readable form only. The bundle is
    # large and would drown the report it belongs to.
    print STDERR $text;

    if (open(my $fh, '>>', $self->aux_file)) {
        print $fh $text;

        # One physical line, so the collector turns the whole bundle into a
        # single info facet rather than one per line. encode_json escapes
        # embedded newlines, so this holds however long the bundle gets. It can
        # be pulled back out of that facet later; a binary attachment would be
        # tidier but the aux log carries text only.
        print $fh $json, "\n";

        close($fh);
    }

    my $file = $self->json_file($bundle->{round});
    my $ok   = eval { write_file_atomic($file, $json . "\n"); 1 };
    warn "Could not write stall report '$file': $@" unless $ok;

    return $text;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Stall::Report - Render and deliver a stall report.

=head1 DESCRIPTION

Turns a capture bundle into something a person and an analysis agent can both
read, and puts it where both will find it.

Reports go to two places. The main process's STDERR is never redirected by
yath, so it reaches the CI log directly, even if the event pipeline is itself
unhealthy. C<aux_logs/stall-STDERR.log> is picked up by
L<Test2::Harness::Collector>, which re-reads that directory on every poll and
tags anything ending C<-STDERR.log> as debug output, so it reaches the yath UI
with no new plumbing.

The runner's C<error.log> is deliberately not used: it is opened without
append, so a second writer and the runner would overwrite each other.

The full bundle is also written as JSON, twice. Once to the aux log as a
single physical line, so it reaches the yath UI as one info facet and can be
pulled back out later. Once to a file, outside the working directory, because
for a plain C<yath test> that directory is temporary and is removed when the
run ends; that copy goes to the directory yath was run from unless
C<--stall-report-dir> says otherwise. The text report is a reduced view; open files, locks, the process
tree and C<strace> output live only in the JSON. Begin and end markers let the
text be extracted from a log by pattern.

=head1 SYNOPSIS

    use Test2::Harness::Stall::Report;

    my $report = Test2::Harness::Stall::Report->new(
        workdir => $workdir,
        run_id  => $run_id,
    );

    $bundle->{state_summary} = $report->state_summary($state, $tasks);
    $report->emit($bundle);

=head1 ATTRIBUTES

=over 4

=item $string = $report->workdir()

The run's working directory, used for the aux log.

=item $string = $report->run_id()

Names the JSON bundle, so bundles from different runs can sit together.

=item $string = $report->report_dir()

Where the JSON bundle is written. Defaults to the directory yath was run
from.

=back

=head1 PUBLIC METHODS

=over 4

=item $hashref = $report->state_summary($state, $tasks)

What the run looked like, taken from the replay rather than any live harness
object.

=item $string = $report->render($bundle)

The human-readable report, between begin and end markers.

=item $string = $report->emit($bundle)

Renders, writes to both channels and the JSON bundle, and returns the text.

=item $string = $report->headline($bundle)

One line saying what was observed.

=item $string = $report->task_lines($label, $tasks)

A bounded list of tests; the full list is in the JSON.

=item $string = $report->json_file($round)

Where the bundle for a given report is written.

=item $string = $report->aux_file()

The aux log the collector forwards.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
