package App::Yath2::Renderer2::JUnit;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Renderer2::Base';

use Carp qw/croak/;

# Flat-namespaced option group owned by this renderer. The `junit`
# prefix is registered as exclusively owned by this class through
# App::Yath2::Renderer2::Registry; a second renderer attempting to
# claim the same prefix triggers a registration-time error.
use Getopt::Yath;
option_group {group => 'junit', prefix => 'junit', category => 'JUnit renderer options'} => sub {
    option out => (
        type        => 'Scalar',
        description => 'Path to write the JUnit XML report to. Required when this renderer is active.',
        long_examples  => [' PATH'],
        short_examples => [' PATH'],
    );
};

# Override init to set required criticality. JUnit is a file-producing
# renderer — if it fails to write the XML, CI has no test results. The
# required criticality means a failure here affects the command exit code.
sub init {
    my $self = shift;
    $self->{criticality} //= 'required';
    $self->SUPER::init();
    return;
}

# start — validate that an output path is configured before the loop begins.
# Fail early so the error message is clear rather than dying at finish.
sub start {
    my $self = shift;
    croak "JUnit renderer requires a non-empty output path (set --junit-out PATH)"
        unless length($self->_out_path // '');
    return;
}

# Resolve the output path from settings. Accepts either the new flat
# `--junit-out` option (lands in $settings->{junit}{out} when settings
# is a Settings object, or $settings->{junit_out} when passed as a
# plain hashref keyed by the legacy name) or the legacy `junit_out`
# hashref key for callers constructing the renderer directly from a
# plain hashref.
sub _out_path {
    my $self = shift;
    my $s    = $self->settings or return undef;

    if (ref($s) eq 'HASH') {
        return $s->{junit_out} if defined $s->{junit_out};
        return undef unless ref($s->{junit}) eq 'HASH';
        return $s->{junit}{out};
    }

    # Settings object form.
    return undef unless $s->can('junit');
    my $junit = $s->junit;
    return $junit->{out} if ref($junit) eq 'HASH';
    return $junit->out   if $junit && $junit->can('out');
    return undef;
}

# JUnit doesn't emit anything per-producer during the run; everything
# is built at finish() from the log descriptor API. All producer hooks
# stay as the default no-ops inherited from Base.

# finish — walk the log once and emit the full <testsuites> document.
sub finish {
    my $self = shift;
    my $log  = $self->log;
    my $out  = $self->_out_path;

    my @suites;
    for my $run_p ($log->run_producers->all) {
        my @cases;
        for my $job_p ($log->job_producers($run_p->id)->all) {
            push @cases, $self->_build_testcase($job_p);
        }

        my $tests    = scalar @cases;
        my $failures = grep { $_->{failure} } @cases;
        my $errors   = grep { $_->{error} } @cases;
        my $skipped  = grep { $_->{skipped} } @cases;
        my $time     = 0;

        push @suites, {
            id       => $run_p->id,
            name     => "run_" . $run_p->id,
            tests    => $tests,
            failures => $failures,
            errors   => $errors,
            skipped  => $skipped,
            time     => $time,
            cases    => \@cases,
        };
    }

    my $xml = $self->_render_xml(\@suites);

    open(my $fh, '>', $out) or croak "open $out: $!";
    print {$fh} $xml;
    close($fh) or croak "close $out: $!";
    return;
}

# _build_testcase($job_p) — derive a testcase hashref from a job producer.
#
# Jobs that never sealed (state != 'sealed' or pass undef) become <error>
# elements so CI knows the job is incomplete rather than a clean failure.
# Failing jobs read their events artifact to collect assert-failure and
# error-facet details for the <failure> body.
sub _build_testcase {
    my ($self, $job_p) = @_;
    my $name = "job_" . $job_p->id . "_try_" . ($job_p->try // 0);
    my $tc   = {
        name      => $name,
        classname => $name,
    };

    if ($job_p->state ne 'sealed' || !defined $job_p->pass) {
        $tc->{error} = "Job did not complete (state=" . $job_p->state . ")";
        return $tc;
    }

    if (!$job_p->pass) {
        my $body   = '';
        my $reader = $job_p->artifact('events');
        if ($reader) {
            while (defined(my $item = $reader->readline)) {
                next unless ref $item eq 'HASH';
                my $fd = $item->{facet_data} or next;
                if (my $a = $fd->{assert}) {
                    if (!$a->{pass}) {
                        $body .= "FAIL: " . ($a->{details} // '') . "\n";
                    }
                }
                if (my $errs = $fd->{errors}) {
                    for my $e (@$errs) {
                        $body .= "ERROR: " . ($e->{details} // '') . "\n";
                    }
                }
            }
        }
        $tc->{failure} = $body || 'Job failed';
    }

    return $tc;
}

# _render_xml(\@suites) — build the full XML string from collected suite data.
# No external XML module dependency — the schema is simple and well-bounded.
sub _render_xml {
    my ($self, $suites) = @_;

    my $total_tests = 0;
    my $total_fail  = 0;
    my $total_err   = 0;
    for my $s (@$suites) {
        $total_tests += $s->{tests};
        $total_fail  += $s->{failures};
        $total_err   += $s->{errors};
    }

    my @lines;
    push @lines, q{<?xml version="1.0" encoding="UTF-8"?>};
    push @lines, sprintf(
        q{<testsuites tests="%d" failures="%d" errors="%d">},
        $total_tests, $total_fail, $total_err,
    );

    for my $s (@$suites) {
        push @lines, sprintf(
            q{  <testsuite id="%s" name="%s" tests="%d" failures="%d" errors="%d" skipped="%d" time="%g">},
            _xml_esc($s->{id}),
            _xml_esc($s->{name}),
            $s->{tests}, $s->{failures}, $s->{errors}, $s->{skipped},
            $s->{time},
        );
        for my $c (@{$s->{cases}}) {
            push @lines, sprintf(
                q{    <testcase name="%s" classname="%s">},
                _xml_esc($c->{name}), _xml_esc($c->{classname}),
            );
            if ($c->{failure}) {
                push @lines, q{      <failure>};
                push @lines, "        " . _xml_esc($c->{failure});
                push @lines, q{      </failure>};
            }
            if ($c->{error}) {
                push @lines, q{      <error>};
                push @lines, "        " . _xml_esc($c->{error});
                push @lines, q{      </error>};
            }
            push @lines, q{    </testcase>};
        }
        push @lines, q{  </testsuite>};
    }

    push @lines, q{</testsuites>};
    return join("\n", @lines) . "\n";
}

# _xml_esc($str) — escape the five XML metacharacters.
# Returns empty string for undef input.
sub _xml_esc {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&apos;/g;
    return $s;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::JUnit - Self-contained JUnit XML renderer built at finish time.

=head1 SYNOPSIS

    use App::Yath2::Renderer2::JUnit;
    use App::Yath2::Renderer2::Loop;

    my $r = App::Yath2::Renderer2::JUnit->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => { junit_out => '/tmp/results.xml' },
    );
    App::Yath2::Renderer2::Loop::run($r);

=head1 DESCRIPTION

C<App::Yath2::Renderer2::JUnit> produces a JUnit-compatible XML report for
every test run. It is B<self-contained>: no XML formatter accumulates events
during the run. Instead, the entire C<< <testsuites> / <testsuite> /
<testcase> >> document is assembled in C<finish()> by reading the sealed
log's producer descriptors and, for failing jobs, replaying their stored
events artifact.

=head2 Required path

The C<junit_out> key in the C<settings> hashref must be set to a non-empty
file path before C<start()> is called. C<start()> will croak immediately if
the setting is absent or empty, so misconfiguration is caught before the run
begins rather than at the end.

=head2 Criticality

The default criticality for this renderer is C<'required'>. If writing the
XML file fails, the command exits non-zero. CI pipelines consuming JUnit
output need the file to be present; a missing or truncated report is an
error condition, not a cosmetic inconvenience.

=head2 XML schema

The generated document follows the de-facto JUnit XML schema:

=over 4

=item * One C<< <testsuite> >> per run, named C<< run_<id> >>.

=item * One C<< <testcase> >> per job, named C<< job_<id>_try_<try> >>.

=item * Passing jobs: empty C<< <testcase> >> element.

=item * Failing jobs: C<< <testcase> >> containing a C<< <failure> >> child
with assertion details extracted from the events artifact.

=item * Incomplete jobs (not sealed, or C<pass> undefined): C<< <testcase> >>
containing an C<< <error> >> child noting the job did not complete.

=back

=head1 SETTINGS

=over 4

=item C<junit_out> (required)

Filesystem path where the XML file will be written. The file is created or
overwritten at C<finish()> time.

=item C<poll_interval> (optional)

Forwarded to the render loop's LIVE-file monitor when replaying a live run.
Defaults to 0.05 seconds if not set.

=back

=head1 METHODS

=over 4

=item $r->start

Validates that C<junit_out> is set in C<settings>. Croaks immediately with a
clear message when the path is absent or empty.

=item $r->finish

Walks the log's run and job producers, collects testcase data, and writes the
complete XML document to the C<junit_out> path.

=item $r->_build_testcase($job_producer)

Returns a hashref describing one testcase. Incomplete jobs get an C<error>
key; failing jobs get a C<failure> key containing assertion details. Passing
jobs get neither.

=item $r->_render_xml(\@suites)

Assembles and returns the complete XML string from the list of suite
hashrefs. No external XML library is required; the schema is simple and
well-bounded.

=item App::Yath2::Renderer2::JUnit::_xml_esc($str)

Escapes C<&>, C<< < >>, C<< > >>, C<">, and C<'> for XML attribute and
element text content. Returns an empty string for C<undef> input.

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

See L<http://dev.perl.org/licenses/>

=cut
