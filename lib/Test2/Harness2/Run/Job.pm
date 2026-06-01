package Test2::Harness2::Run::Job;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    <run_uuid
    <run_ord
    <job_uuid
    <job_ord

    try
    state

    <absolute
    <relative
    <stage
    <category
    <duration
    <max_slots
    <ch_dir
    <event_timeout
    <post_exit_timeout

    +min_slots
    +comment
    +conflicts
    +switches
    +features
    +meta
    +preload_preferences
    +smoke
    +isolation
    +retry
    +retry_isolated
    +non_perl
    +is_binary
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::Job - The final, static description of one test file to run.

=head1 DESCRIPTION

A value object representing a single test file scheduled inside a
L<Test2::Harness2::Run>. By the time the C<Test2::Harness2> namespace sees a
job it is in its B<final form>: every attribute that could come from
investigating the test file (category, duration, conflicts, switches, feature
toggles, slot requirements, timeouts, retry policy, etc.) is already populated.

This class does B<not> scan files, read shebangs, parse directives, stat the
filesystem, or otherwise build that state. Producing a complete job -- reading
C<HARNESS2:> directives, applying CLI overrides, classifying the file -- is the
job of the C<App::Yath2> namespace. The harness consumes the result. The only
construction-time convenience this class allows is deriving C<absolute> /
C<relative> from a C<file> argument (a pure path computation, no I/O).

The history-of-a-test-file-across-runs concept (the C<test_files> table) is a
database / front-end construct; it does not exist here. The harness only needs
to iterate the jobs it was handed.

=head1 SYNOPSIS

    use Test2::Harness2::Run::Job;

    my $job = Test2::Harness2::Run::Job->new(
        run_uuid => $run_uuid,
        run_ord  => 1,
        job_uuid => $job_uuid,
        job_ord  => 1,
        file     => 't/foo.t',    # derives absolute + relative
        category => 'general',
        duration => 'short',
        conflicts => ['db'],
        features  => {fork => 0},
    );

    printf "job %s: %s (try %d, %s)\n",
        $job->job_uuid, $job->relative, $job->try, $job->state;

=head1 ATTRIBUTES

=head2 Identity and runtime state

=over 4

=item run_uuid (required)

UUID of the parent run.

=item run_ord (required)

Numeric order of the parent run (order queued, starting at 1).

=item job_uuid (required)

UUID for this job.

=item job_ord (required)

Numeric order of this job within its run, starting at 1.

=item try

Retry counter. Defaults to 1. The only mutable identity-side attribute besides
L</state>.

=item state

Scheduler lifecycle state: C<'pending'>, C<'running'>, or C<'done'>. Defaults
to C<'pending'>.

=back

=head2 Scan-derived attributes

These are populated by the producer (C<App::Yath2>) from the test file. The
harness treats them as read-only inputs.

=over 4

=item absolute, relative (one of these, or C<file>, is required)

Absolute and relative paths to the test file. May be derived from a C<file>
argument at construction.

=item stage, category, duration

Scheduler hints. C<undef> by default; C<check_category> and C<check_duration>
supply C<'general'> / C<'medium'> fallbacks.

=item min_slots, max_slots

Slot requirements. C<min_slots> defaults to 1; C<max_slots> defaults to
C<undef> (interpreted per-resource).

=item conflicts

Arrayref of conflict tags. Two jobs sharing a tag must not run at the same
time. Default C<[]>.

=item smoke, isolation, retry, retry_isolated, non_perl, is_binary

Integer / boolean classifiers. Default C<0>. C<retry> is the allowed retry
count (distinct from the runtime L</try> counter).

=item switches

Arrayref of perl switches. Default C<[]>.

=item features

Hashref of feature toggles. Default C<{}>.

=item meta

Hashref of free-form metadata. Default C<{}>.

=item preload_preferences

Ordered arrayref of preload-name tokens. Default C<< ['<default>'] >>.

=item ch_dir

Directory to chdir into before running, or C<undef>.

=item event_timeout, post_exit_timeout

Idleness timeouts in seconds. Default C<undef>.

=item comment

Comment character for any directive parser built on top. Default C<'#'>.

=back

=cut

# Per-feature defaults consulted by check_feature when the caller supplies no
# explicit default and the job's data has no entry for the feature.
my %FEATURE_DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    run       => 1,
    isolation => 0,
    smoke     => 0,
    io_events => 1,
);

# Static rank table used by rank() to sort jobs into an efficient run order.
my %RANK = (
    smoke      => 1,
    immiscible => 10,
    long       => 20,
    medium     => 50,
    short      => 80,
    isolation  => 100,
);

sub init ($self) {
    croak "'run_uuid' is a required attribute" unless defined $self->{+RUN_UUID} && length $self->{+RUN_UUID};
    croak "'run_ord' is a required attribute"  unless defined $self->{+RUN_ORD};
    croak "'job_uuid' is a required attribute" unless defined $self->{+JOB_UUID} && length $self->{+JOB_UUID};
    croak "'job_ord' is a required attribute"  unless defined $self->{+JOB_ORD};

    # Accept a `file` argument for convenience; derive the path forms from it
    # and discard it (no `file` slot exists). This is pure path math, not a
    # filesystem scan.
    if (my $file = delete $self->{file}) {
        $self->{+ABSOLUTE} //= File::Spec->rel2abs($file);
        $self->{+RELATIVE} //= File::Spec->abs2rel($file);
    }

    croak "'absolute' (or 'file') is a required attribute"
        unless defined $self->{+ABSOLUTE} && length $self->{+ABSOLUTE};

    # Ensure both derived forms are present even when only one was supplied.
    $self->{+ABSOLUTE} //= File::Spec->rel2abs($self->{+RELATIVE});
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+ABSOLUTE});

    $self->{+TRY}   //= 1;
    $self->{+STATE} //= 'pending';

    return;
}

# Default-aware readers for attributes with non-undef defaults. The slot is
# left unset until a producer fills it; the reader returns the documented
# default in the meantime. The container-valued readers build a fresh
# default each call so a mutated default never leaks between jobs.
sub min_slots           ($self) { defined $self->{+MIN_SLOTS}           ? $self->{+MIN_SLOTS}           : 1 }
sub comment             ($self) { defined $self->{+COMMENT}             ? $self->{+COMMENT}             : '#' }
sub conflicts           ($self) { defined $self->{+CONFLICTS}           ? $self->{+CONFLICTS}           : [] }
sub switches            ($self) { defined $self->{+SWITCHES}            ? $self->{+SWITCHES}            : [] }
sub features            ($self) { defined $self->{+FEATURES}            ? $self->{+FEATURES}            : {} }
sub meta                ($self) { defined $self->{+META}                ? $self->{+META}                : {} }
sub preload_preferences ($self) { defined $self->{+PRELOAD_PREFERENCES} ? $self->{+PRELOAD_PREFERENCES} : ['<default>'] }
sub smoke               ($self) { $self->{+SMOKE}          // 0 }
sub isolation           ($self) { $self->{+ISOLATION}      // 0 }
sub retry               ($self) { $self->{+RETRY}          // 0 }
sub retry_isolated      ($self) { $self->{+RETRY_ISOLATED} // 0 }
sub non_perl            ($self) { $self->{+NON_PERL}       // 0 }
sub is_binary           ($self) { $self->{+IS_BINARY}      // 0 }

=head1 PUBLIC METHODS

=cut

=over 4

=item @fields = $job->json_fields

Ordered list of attribute names C<TO_JSON> emits.

=item $hashref = $job->TO_JSON

A JSON-ready hashref of every C<json_fields> attribute, read via its accessor.

=item $val = $job->feature($name)

Shortcut for C<< $job->features->{$name} >>; C<undef> when absent.

=item $bool = $job->check_feature($name, $default?)

Pure lookup of a feature toggle as 0/1. Falls back to C<$default>, or to an
internal table (C<timeout>, C<fork>, C<preload>, C<stream>, C<run>,
C<io_events> default 1; C<isolation>, C<smoke> default 0) when C<$default> is
omitted.

=item $category = $job->check_category

C<category>, or C<'general'> when undef.

=item $duration = $job->check_duration

C<duration>, or C<'medium'> when undef.

=item $stage = $job->check_stage

=item $n = $job->check_min_slots

=item $n = $job->check_max_slots

=item $n = $job->check_retry

=item $bool = $job->check_retry_isolated

Raw accessors exposed under the C<check_*> names used by the resource layer; no
fallbacks beyond the per-attribute defaults.

=item @tags = $job->conflicts_list

Conflict tags as a list (empty when none).

=item $bool = $job->has_conflicts

True when C<conflicts_list> is non-empty.

=item $bool = $job->is_executable

True when the file at C<absolute> has its executable bit set.

=item @values = $job->meta_get($key)

List of values stored under C<$key> in L</meta>, or an empty list.

=item $rank = $job->rank

Integer sort key for run order; lower runs earlier. Smoke jobs rank 1; otherwise
category then duration, falling back to 1.

=back

=cut

sub json_fields ($self) {
    return qw{
        run_uuid run_ord job_uuid job_ord
        try state
        absolute relative
        stage category duration
        min_slots max_slots
        conflicts
        smoke isolation
        retry retry_isolated
        non_perl is_binary
        switches
        features meta
        preload_preferences
        ch_dir
        event_timeout post_exit_timeout
        comment
    };
}

sub TO_JSON ($self) {
    return {map { $_ => $self->$_ } $self->json_fields};
}

sub feature ($self, $name = undef) {
    return undef unless defined $name;
    return $self->features->{$name};
}

sub check_feature ($self, $name = undef, $default = undef) {
    return $default                     unless defined $name;
    $default = $FEATURE_DEFAULTS{$name} unless defined $default;

    my $features = $self->features;
    my $set      = $features->{$name};
    return $default unless defined $set;
    return $set ? 1 : 0;
}

sub check_category       ($self) { return $self->category // 'general' }
sub check_duration       ($self) { return $self->duration // 'medium' }
sub check_stage          ($self) { return $self->stage }
sub check_min_slots      ($self) { return $self->min_slots }
sub check_max_slots      ($self) { return $self->max_slots }
sub check_retry          ($self) { return $self->retry }
sub check_retry_isolated ($self) { return $self->retry_isolated }

sub conflicts_list ($self) {
    my $c = $self->conflicts;
    return $c ? @$c : ();
}

sub has_conflicts ($self) { return scalar($self->conflicts_list) ? 1 : 0 }
sub is_executable ($self) { return -x $self->absolute }

sub meta_get ($self, $key = undef) {
    my $hash = $self->meta;
    return () unless defined $key && $hash->{$key};
    return @{$hash->{$key}};
}

sub rank ($self) {
    return $RANK{smoke} if $self->check_feature('smoke');
    return $RANK{$self->check_category} || $RANK{$self->check_duration} || 1;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
