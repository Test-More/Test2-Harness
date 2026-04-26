package Test2::Harness2::Collector::Auditor::Test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;
use Time::HiRes qw/time/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util qw/hub_truth parse_exit/;
use Test2::Harness2::Event;

use Role::Tiny::With;
with 'Test2::Harness2::Role::Auditor';

use Object::HashBase qw{
    <run_id
    <job_id
    <job_try
    <ipcm_info
    -assertion_count
    -exit
    -plan
    +fail
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -nested
    -subtests
    -numbers
    -halt
    -failed_subtest_tree
    -passing_subtests
    -failing_subtests
};

# Attribute reference:
#   run_id              -- identifier of the run this auditor belongs to (used in harness_job_exit).
#   job_id              -- identifier of the job (test) this auditor belongs to (used in harness_job_exit).
#   job_try             -- 0-based attempt number for this job (used in harness_job_exit).
#   assertion_count     -- total assertions seen so far (passing + failing, sans amnesty bookkeeping).
#   exit                -- raw wait-status integer captured from the harness_process_exit facet, undef until seen.
#   plan                -- the plan facet hashref once observed (count / details / etc.), undef otherwise.
#   fail                -- latched flag set true once fail() determines the run cannot pass; sticky thereafter.
#   _errors             -- count of error/control facets that flagged failure or halt.
#   _failures           -- count of failing assertions not covered by amnesty (todo).
#   _sub_failures       -- count of subtests whose own auditing concluded they failed.
#   _plans              -- number of plan facets seen; >1 triggers a "too many plans" failure.
#   nested              -- subtest nesting depth this auditor represents; 0 for the top-level run.
#   subtests            -- map of nested-depth -> in-progress subtest state (start event + collected child facets).
#   numbers             -- map of TAP assertion-number -> times-seen, for duplicate / missing-number detection.
#   halt                -- human-readable bail-out reason if a control facet halted the run, undef otherwise.
#   failed_subtest_tree -- nested arrayref describing the path through any failed subtests for diagnostics.
#   passing_subtests    -- arrayref of names of subtests that have passed at this auditor's nesting level.
#   failing_subtests    -- arrayref of names of subtests that have failed at this auditor's nesting level.

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+_SUB_FAILURES}   = 0;
    $self->{+_PLANS}          = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS}          = {};
    $self->{+SUBTESTS}         = {};
    $self->{+PASSING_SUBTESTS} = [];
    $self->{+FAILING_SUBTESTS} = [];

    $self->{+NESTED} //= 0;
}

sub set_process_info {
    my ($self, %info) = @_;
    $self->{+RUN_ID}  = $info{run_id}  if exists $info{run_id};
    $self->{+JOB_ID}  = $info{job_id}  if exists $info{job_id};
    $self->{+JOB_TRY} = $info{job_try} if exists $info{job_try};
    return;
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

sub passing { !$_[0]->failing }
sub failing { $_[0]->fail_count ? 1 : 0 }

sub pass { !$_[0]->fail }

sub fail {
    my $self = shift;
    return $self->{+FAIL}     if $self->{+FAIL};
    return $self->{+FAIL} = 1 if $self->fail_error_facet_list;
    return 0;
}

sub fail_count {
    my $self  = shift;
    my $count = $self->{+_FAILURES} + $self->{+_ERRORS} + $self->{+_SUB_FAILURES};
    $count++ if $self->{+HALT};
    $count++ if defined($self->{+EXIT}) && $self->{+EXIT} != 0;
    $count++ if !$count                 && $self->{+FAIL};
    return $count;
}

sub pass_count {
    my $self   = shift;
    my $passes = $self->{+ASSERTION_COUNT} - $self->{+_FAILURES};
    return $passes < 0 ? 0 : $passes;
}

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

sub audit_event {
    my $self = shift;
    my ($event) = @_;

    $self->_normalize_event($event);

    my @out;
    for my $se ($self->_audit($event)) {
        $self->_normalize_event($se);
        delete $se->{facet_data}->{harness}->{closed_by}
            if $se->{facet_data} && $se->{facet_data}->{harness};
        push @out => $se;
    }

    return @out;
}

sub _normalize_event {
    my $self = shift;
    my ($event) = @_;

    my $f = $event->{facet_data} //= {};

    # event_id lives in three places that must agree: the top-level key, the
    # harness facet, and the about facet's uuid. Any two set to different
    # values indicates an upstream bug -- refuse to paper over it. Read
    # through intermediate hashrefs only when they already exist so we do
    # not autovivify empty facets just to inspect them.
    my %sources;
    $sources{$event->{event_id}} = 'event' if defined $event->{event_id};
    $sources{$f->{harness}{event_id}} //= 'harness facet' if $f->{harness} && defined $f->{harness}{event_id};
    $sources{$f->{about}{uuid}}       //= 'about facet'   if $f->{about}   && defined $f->{about}{uuid};

    if (keys(%sources) > 1) {
        croak "event_id mismatch across facets: " . join(', ', map { "$sources{$_}='$_'" } sort keys %sources);
    }

    my $event_id = $event->{event_id} // ($f->{harness} && $f->{harness}{event_id}) // ($f->{about} && $f->{about}{uuid}) // gen_uuid();

    $event->{event_id} = $event_id;

    # harness gets stamped with the event_id; about is only stamped when the
    # caller already put an about facet in place so we do not create one just
    # to hold a uuid.
    $f->{harness}{event_id} //= $event_id;
    $f->{about}{uuid}       //= $event_id if $f->{about};
}

sub _audit {
    my $self = shift;
    my ($event) = @_;

    my $f  = $event->{facet_data};
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    return $event if $hf->{buffered};

    my $is_ours = $nested == $self->{+NESTED};

    return $event unless $is_ours || $f->{from_tap};

    return $event if $f->{from_tap}    && $f->{from_tap}->{source} eq 'STDERR';
    return $event if $f->{from_stream} && $f->{from_stream}->{source} eq 'STDERR';

    if ($f->{harness} && $f->{harness}->{subtest_start}) {
        my $st = $self->{+SUBTESTS}->{$nested + 1} ||= {};
        $st->{event} = $event;
        $f->{harness_auditor}->{no_render} = 1;
        $self->_drop_compressed_cache($event);

        # Only announce at this auditor's own nesting level -- nested
        # subtest_start events that slip past the from_tap gate above are
        # still swallowed as before. Downstream consumers that watch for
        # harness.subtest_started therefore only see the top-level
        # announcements produced by the top-level auditor.
        return unless $is_ours;

        # Emit a synthetic announcement event so downstream loggers can react
        # to a subtest starting without snooping on the swallowed raw event.
        # Carry the original event's trace and timestamps so consumers can
        # correlate the announcement with the source location.
        my $stamp    = $event->{stamp} // $f->{harness}->{stamp} // time;
        my $announce = Test2::Harness2::Event->new(
            event_id   => gen_uuid(),
            stamp      => $stamp,
            facet_data => {
                harness => {
                    subtest_started => 1,
                    nested          => $nested,
                    stamp           => $stamp,
                },
                (defined $f->{trace} ? (trace => {%{$f->{trace}}}) : ()),
            },
        );
        $self->_normalize_event($announce);
        return $announce;
    }

    my @out;

    if ($f->{from_tap} && $f->{harness}->{subtest_end} && !($self->{+SUBTESTS} && keys %{$self->{+SUBTESTS}})) {
        $f->{harness_auditor}->{no_render} = 1;
        $self->_drop_compressed_cache($event);

        my $stamp = $f->{trace}->{stamp} // $f->{stamp} // $f->{harness}->{stamp} // time;

        $f = {
            %{$f},
            harness_auditor => {added_by_auditor => 1},
            parent          => undef,
            trace           => undef,
            harness         => {
                stamp => $stamp,
                %{$f->{harness} || {}},
                subtest_end => undef,
            },
            info => [
                @{$f->{info} || []},
                {
                    details      => $f->{from_tap}->{details},
                    tag          => $f->{from_tap}->{source} || 'STDOUT',
                    from_harness => 1,
                }
            ],
        };

        $event = Test2::Harness2::Event->new(
            event_id   => $f->{harness}->{event_id} // $f->{about}->{uuid} // gen_uuid(),
            stamp      => $stamp,
            facet_data => $f,
        );
        $self->_normalize_event($event);
    }

    push @out => $event unless $f->{harness}->{subtest_end};

    if (my $sts = $self->{+SUBTESTS}) {
        my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;

        for my $n (@close) {
            my $st = delete $sts->{$n};
            my $se = $st->{event} || $event;

            my $fd = $se->{facet_data};
            delete $fd->{harness_auditor}->{no_render};
            $fd->{parent}->{hid}      ||= $n;
            $fd->{parent}->{children} ||= $st->{children};
            $fd->{harness}->{closed_by}     = $event;
            $fd->{harness}->{closed_by_eid} = $event->{event_id};
            $self->_drop_compressed_cache($se);

            my $pn = $n - 1;

            if ($st->{event}) {
                if ($pn > $self->{+NESTED}) {
                    push @{$sts->{$pn}->{children}} => $fd;
                }
                elsif ($pn == $self->{+NESTED}) {
                    $self->_subtest_process($fd, $se);
                    push @out => $se;
                }
            }
            else {
                push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
            }
        }
    }

    unless ($is_ours) {
        my $st = $self->{+SUBTESTS}->{$nested} ||= {};
        my $fd = {%$f};
        push @{$st->{children}} => $fd;
        return @out;
    }

    $self->_subtest_process($f, $event);
    return @out;
}

sub _subtest_process {
    my $self = shift;
    my ($f, $event) = @_;

    # _subtest_process mutates $f (== $event->facet_data when an
    # event is passed) extensively below: deleting harness.closed_by,
    # toggling subtest_closed, pushing errors, etc. Drop the
    # collector's cached on-wire compressed frame so a downstream
    # zstd-aware logger recompresses against the post-audit body.
    $self->_drop_compressed_cache($event) if $event;

    my $closer = delete $f->{harness}->{closed_by};

    unless ($event) {
        $event = Test2::Harness2::Event->new(
            event_id   => $f->{harness}->{event_id} // $f->{about}->{uuid} // gen_uuid(),
            facet_data => $f,
        );
        $self->_normalize_event($event);
    }

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    if ($f->{parent} && $f->{assert}) {
        my $name = $f->{assert}->{details} // "unnamed subtest ($f->{trace}->{frame}->[1] line $f->{trace}->{frame}->[2])";

        my $subauditor = blessed($self)->new(
            nested    => $self->{+NESTED} + 1,
            run_id    => $self->{+RUN_ID},
            job_id    => $self->{+JOB_ID},
            job_try   => $self->{+JOB_TRY},
            ipcm_info => $self->{+IPCM_INFO},
        );

        for my $sf (@{$f->{parent}->{children}}) {
            $sf->{about}->{uuid}       ||= gen_uuid();
            $sf->{harness}->{event_id} ||= $sf->{about}->{uuid};
            $subauditor->_subtest_process($sf);
        }

        my @errors = $subauditor->subtest_fail_error_facet_list();

        if ($f->{harness}->{subtest_start}) {
            if ($closer && $closer->{facet_data}->{harness}->{subtest_end}) {
                $f->{harness}->{subtest_closed} = 1;
            }
            elsif (!$f->{harness}->{subtest_closed}) {
                push @{$f->{errors}} => {
                    tag          => 'REASON',
                    fail         => 1,
                    from_harness => 1,
                    details      => "Buffered subtest ended abruptly (missing closing brace event)",
                };
            }
        }

        my $fail = 0;
        if (@errors) {
            push @{$f->{errors}} => @errors;
            $fail = 1;
        }
        else {
            $fail ||= $f->{assert}  && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
            $fail ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
            $fail ||= $f->{errors}  && first { $_->{fail} } @{$f->{errors}};
        }

        if ($fail) {
            $self->{+_SUB_FAILURES}++;

            my $tree = $self->{+FAILED_SUBTEST_TREE} //= [];
            push @$tree => [$name, $subauditor->{+FAILED_SUBTEST_TREE} // []];

            push @{$self->{+FAILING_SUBTESTS} //= []} => $name;
        }
        else {
            push @{$self->{+PASSING_SUBTESTS} //= []} => $name;
        }
    }

    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    if ($f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
        $self->{+_FAILURES}++;
    }

    if ($f->{control} || $f->{errors}) {
        my $err = $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $err;
        $self->{+HALT} = $f->{control}->{details} || '1'
            if $f->{control} && $f->{control}->{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1');
    }

    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    if (my $px = $f->{harness_process_exit}) {
        $self->{+EXIT} = $px->{all};

        $f->{harness_job_exit} //= {
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},
            exit    => $px->{all},
            codes   => $px,
            stamp   => $event->{stamp} // $f->{harness}->{stamp} // time,
            (defined $px->{times}       ? (times       => $px->{times})       : ()),
            (defined $px->{child_times} ? (child_times => $px->{child_times}) : ()),
            (defined $px->{child_wall}  ? (child_wall  => $px->{child_wall})  : ()),
        };

        push @{$f->{errors}} => $self->fail_error_facet_list;
    }

    return;
}

sub subtest_fail_error_facet_list {
    my $self = shift;

    my @out;

    my $plan  = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            if (!$numbers->{$i}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was never seen"};
            }
            elsif ($numbers->{$i} > 1) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was seen more than once"};
            }
        }
    }

    if (!$self->{+_PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared"};
        }
        else {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared, and no assertions were made."};
        }
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Too many plans were declared (Count: $self->{+_PLANS})"};
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Planned for $plan assertions, but saw $count"}
        if $plan && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})"}
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list {
    my $self = shift;

    my @out;

    my $incomplete_subtests = values %{$self->{+SUBTESTS}};
    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "One or more incomplete subtests (Count: $incomplete_subtests)"}
        if $incomplete_subtests;

    if (defined(my $wstat = $self->{+EXIT})) {
        if ($wstat == -1) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "The harness could not get the exit code! (Code: $wstat)"};
        }
        elsif ($wstat) {
            my $e = parse_exit($wstat);
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Err: $e->{err})"}
                if $e->{err};
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Signal: $e->{sig})"}
                if $e->{sig};
        }
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Errors were encountered (Count: $self->{+_ERRORS})"}
        if $self->{+_ERRORS};

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion failures were encountered (Count: $self->{+_FAILURES})"}
        if $self->{+_FAILURES};

    push @out => $self->subtest_fail_error_facet_list();

    return @out;
}

# Drop the collector's cached on-wire compressed JSON frame and the
# matching as_json cache from $event. Auditors call this immediately
# before mutating the event body so a downstream zstd-aware logger
# does not write stale bytes that no longer match the post-audit
# event. Tolerates plain hashref events (used by the unit tests) as
# well as blessed Test2::Harness2::Event instances since both are
# hashes underneath.
sub _drop_compressed_cache {
    my ($self, $event) = @_;
    return unless $event;
    delete $event->{compressed_form};
    delete $event->{json};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor::Test - Auditor that determines pass/fail
of a single test execution.

=head1 DESCRIPTION

This auditor consumes events one at a time from a
L<Test2::Harness2::Collector> and decides whether the test process is passing
or failing. It tracks assertions, plans, subtests (including deep nesting),
errors, halts/bail-outs, and the process exit code, and verifies the resulting
state is internally consistent (plan matches assertion count, no duplicate or
missing assertion numbers, no abandoned subtests, etc.).

It implements the L<Test2::Harness2::Role::Auditor> contract: each call to
L</audit_event> returns zero or more events for downstream consumers, and the
auditor may emit additional synthesized events (for example to surface
mismatched assertion counts or buffered-subtest-end recovery).

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Auditor::Test;

    my $auditor = Test2::Harness2::Collector::Auditor::Test->new();

    for my $event (@events) {
        my @forward = $auditor->audit_event($event);
        # forward to loggers...
    }

    print "Pass!\n" if $auditor->pass;
    print "Fail!\n" if $auditor->fail;

=head1 METHODS

=over 4

=item @events = $auditor->audit_event($event)

Process a single event, updating internal state, and return zero or more
events for downstream consumers (loggers, renderers, ...). The returned list
may include the original event, a transformed copy, or additional events
synthesized by the auditor (such as recovery from a stray subtest_end).

=item $int = $auditor->assertion_count()

Number of assertions that have been seen.

=item $int = $auditor->exit()

If the test process has exited and a C<harness_process_exit> facet has been
seen, this returns the raw wait-status integer. Returns C<undef> otherwise.

=item $bool = $auditor->fail()

True if the test is failing.

=item $bool = $auditor->pass()

True if the test is passing.

=item $bool = $auditor->passing()

Alias for L</pass>, satisfying L<Test2::Harness2::Role::Auditor>.

=item $bool = $auditor->failing()

Alias for L</fail>, satisfying L<Test2::Harness2::Role::Auditor>.

=item $n = $auditor->fail_count()

Number of distinct failures seen (assertion failures, errors, failed subtests,
plus halts and non-zero exits).

=item $n = $auditor->pass_count()

Number of passing assertions seen.

=item $bool = $auditor->has_exit()

True once an exit facet has been observed.

=item $bool = $auditor->has_plan()

True once a non-skip plan has been observed.

=item $string = $auditor->halt()

If the test was halted via a bail-out, the human-readable reason. C<undef>
otherwise.

=item $hash = $auditor->numbers()

Internal map of TAP assertion numbers to their occurrence counts. Only
populated for tests that produce TAP.

=item $plan = $auditor->plan()

The plan facet, once seen.

=item $tree = $auditor->failed_subtest_tree()

Nested arrayref describing the path through any failed subtests, suitable for
producing diagnostic summaries.

=item $int = $auditor->nested()

Nesting depth this auditor represents. C<0> for the top-level test, greater
than zero for sub-auditors created to validate nested subtests.

=item @facets = $auditor->fail_error_facet_list()

Internal: a list of error facet hashes describing every reason the test is
failing. Appended to the C<harness_process_exit> event when it is observed.

=item @facets = $auditor->subtest_fail_error_facet_list()

Internal: a list of error facet hashes describing the failures attributable
to a single subtest's contents (plan / assertion-count / number / nested
subtest-failure issues), used recursively for nested subtests.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
