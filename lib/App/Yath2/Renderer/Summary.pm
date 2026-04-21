package App::Yath2::Renderer::Summary;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <io
    +failures
    +per_job
};

use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';

# End-of-run summary renderer. Consumes the event stream -- ignoring
# almost all of it -- and prints a compact summary when the run
# finishes. The artifact-reading layer feeds it the aggregated
# per-job / per-run summary events at end-of-run (IPC_AND_LOGGERS
# §7 run_complete shape); this renderer's job is just to format
# that.
#
# Intentionally minimal: no timing accounting, no per-file details.
# Stage 12's goal is "a clean minimal implementation"; a richer
# summary (CPU usage, wall-time, coverage stats) is a post-parity
# refinement.

sub init {
    my $self = shift;

    $self->{+IO} //= \*STDOUT;
    unless (ref($self->{+IO})) {
        my $path = $self->{+IO};
        open(my $fh, '>', $path)
            or die "Cannot open '$path' for writing: $!";
        $self->{+IO} = $fh;
    }
    $self->{+IO}->autoflush(1) if $self->{+IO}->can('autoflush');

    $self->{+FAILURES} //= [];
    $self->{+PER_JOB}  //= {};

    return;
}

sub event_in {
    my ($self, $event) = @_;

    my $f = ref($event) eq 'HASH' ? $event->{facet_data} // {} : {};
    my $h = $f->{harness};
    return unless ref($h) eq 'HASH';

    # Track per-job verdicts as they arrive. Either test_job_completed
    # or job_completed may arrive depending on which service sent the
    # message.
    my $c = $h->{test_job_completed} || $h->{job_completed};
    if (ref($c) eq 'HASH') {
        my $jid = $c->{job_id} // $h->{job_id};
        return unless defined $jid;

        my $pass = exists $c->{pass} ? ($c->{pass} ? 1 : 0) : 1;
        $self->{+PER_JOB}->{$jid} = {
            job_id => $jid,
            pass   => $pass,
            exit   => $c->{exit},
            file   => $h->{file} // $h->{test_file},
        };

        push @{$self->{+FAILURES}} => $self->{+PER_JOB}->{$jid}
            unless $pass;
    }

    return;
}

sub end_of_run {
    my ($self, %summary) = @_;

    my $rid  = $summary{run_id}     // '(unknown)';
    my $pass = $summary{pass_count} // 0;
    my $fail = $summary{fail_count} // 0;

    my $io = $self->{+IO};

    # Summary box.
    my @lines;
    push @lines => "";
    push @lines => "===== Summary for run $rid =====";
    push @lines => sprintf("%15s: %d", 'Files Passed',    $pass);
    push @lines => sprintf("%15s: %d", 'Files Failed',    $fail);
    if (defined $summary{duration}) {
        push @lines => sprintf("%15s: %.2fs", 'Wall Time', $summary{duration});
    }

    if (my $jobs = $summary{jobs}) {
        my @failed = grep { !$_->{pass} } @$jobs;
        if (@failed) {
            push @lines => "";
            push @lines => "Failed tests:";
            for my $j (@failed) {
                my $name = $j->{file} // $j->{test_file} // $j->{job_id} // '(?)';
                push @lines => "  - $name";
            }
        }
    }
    elsif (@{$self->{+FAILURES}}) {
        # Fall back to the per-event failures we observed in-flight.
        push @lines => "";
        push @lines => "Failed tests:";
        for my $j (@{$self->{+FAILURES}}) {
            my $name = $j->{file} // $j->{job_id} // '(?)';
            push @lines => "  - $name";
        }
    }

    my $verdict = $fail ? "RESULT: FAILED" : "RESULT: PASSED";
    push @lines => "";
    push @lines => $verdict;

    print $io map { "$_\n" } @lines;

    return;
}

sub shutdown { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Summary - End-of-run summary renderer.

=head1 DESCRIPTION

A renderer that accumulates per-job verdicts as events arrive and
prints a compact summary block when the run ends. Consumes
L<App::Yath2::Role::Renderer>.

=head1 ATTRIBUTES

=over 4

=item io

Filehandle (or path string) the renderer writes to. Defaults to
C<STDOUT>. A path string is opened for writing.

=back

=head1 HOOKS

=over 4

=item event_in

Accumulates per-job verdicts from C<test_job_completed> /
C<job_completed> events. Silently ignores everything else.

=item end_of_run

Prints the summary block: files passed, files failed, wall time
(when the layer provides a C<duration>), a list of failing
test files, and a final PASSED/FAILED verdict line.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

See L<https://dev.perl.org/licenses/>

=cut
