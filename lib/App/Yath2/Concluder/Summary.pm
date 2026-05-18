package App::Yath2::Concluder::Summary;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Concluder';

# Walk the Log via run_producers / job_producers, tally pass / fail /
# abandoned per run, and print a banner-framed multi-line summary.
#
# Abandoned: a job that never reached a definitive pass/fail verdict.
# Two distinct cases:
#   * state != 'sealed' (live logs report 'partial' for in-flight jobs).
#   * state == 'sealed' but pass is undefined (the directory backend
#     reports every job as 'sealed' in non-live mode; a missing .sealed
#     marker surfaces as state=sealed + pass=undef, which is a job that
#     was never confirmed complete).
sub run {
    my $self = shift;
    my $log  = $self->log;
    my $fh   = $self->out_fh;

    my $any = 0;
    for my $run_p ($log->run_producers->all) {
        $any++;
        $self->_render_run_summary($fh, $run_p);
    }

    unless ($any) {
        print {$fh} "Yath Summary: no runs in log.\n";
    }

    return;
}

sub _render_run_summary {
    my ($self, $fh, $run_p) = @_;
    my $log = $self->log;

    my ($total, $pass, $fail, $abandoned) = (0, 0, 0, 0);
    my @failed;

    for my $job_p ($log->job_producers($run_p->id)->all) {
        $total++;

        my $st = $job_p->state // 'missing';
        if ($st ne 'sealed') {
            $abandoned++;
            next;
        }

        # state=sealed + pass=undef means the .sealed marker was missing
        # (Directory backend always reports 'sealed' in non-live mode);
        # treat as abandoned rather than failed.
        my $p = $job_p->pass;
        if (!defined $p) {
            $abandoned++;
            next;
        }

        if ($p) {
            $pass++;
        }
        else {
            $fail++;
            push @failed, $job_p;
        }
    }

    my $bar = '=' x 60;

    print {$fh} "$bar\n";
    printf {$fh} "Run %s: %d job%s, %d passed, %d failed, %d abandoned\n",
        $run_p->id,
        $total,
        $total == 1 ? '' : 's',
        $pass,
        $fail,
        $abandoned;

    if (@failed) {
        print {$fh} "Failed jobs:\n";
        for my $j (sort { $a->id cmp $b->id } @failed) {
            printf {$fh} "  - %s (try %s)\n", $j->id, ($j->try // 0);
        }
    }

    my $run_pass = $run_p->pass;
    my $verdict =
        defined $run_pass
        ? ($run_pass ? 'PASSED' : 'FAILED')
        : 'INCOMPLETE';
    my $exit = $run_p->exit;
    printf {$fh} "Result: %s%s\n", $verdict, defined($exit) ? " (exit=$exit)" : '';
    print {$fh} "$bar\n";

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Concluder::Summary - End-of-run pass/fail summary.

=head1 DESCRIPTION

Reads runs and jobs from the Log abstraction and prints a banner-framed
multi-line summary per run: total jobs, pass count, fail count,
abandoned count, the list of failing job ids, and the run's overall
verdict and exit code.

=head1 OUTPUT SHAPE

For each run in the log:

    ============================================================
    Run <id>: <total> jobs, <pass> passed, <fail> failed, <abandoned> abandoned
    Failed jobs:
      - <job_id> (try <n>)
    Result: PASSED|FAILED|INCOMPLETE (exit=<n>)
    ============================================================

C<INCOMPLETE> is used when the run's C<pass> field is C<undef> (run
descriptor not sealed). C<exit=<n>> is omitted when the exit code is not
available. The "Failed jobs:" section is omitted when no jobs failed.

When the log contains no runs at all, a single C<Yath Summary: no runs
in log.> line is printed instead.

A job is counted as abandoned when it never reached a definitive
pass/fail verdict: either the descriptor C<state> is not C<sealed>
(typically C<partial> in live mode), or C<state> is C<sealed> but
C<pass> is undefined (the sealed-directory case where the per-job
C<.sealed> marker is missing).

=head1 METHODS

=over 4

=item $c->run

Drive the summary output. Iterates C<< $log->run_producers->all >>, then
for each run iterates C<< $log->job_producers($run_id)->all >>, tallies,
and writes to C<out_fh>.

=back

=head1 SEE ALSO

L<App::Yath2::Concluder>.

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
