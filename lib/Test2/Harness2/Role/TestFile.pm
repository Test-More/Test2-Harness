package Test2::Harness2::Role::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Role::Tiny;

# file is the only attribute without a sensible default -- every TestFile
# is ultimately about a path. The remaining attributes have defaults
# provided below, which satisfy the role's interface requirement without
# dictating a storage model; consumers that want per-instance overrides
# shadow them (typically via Object::HashBase + init).
requires 'file';

# Per-feature defaults consulted by check_feature when the caller
# supplies no explicit default and the consumer's data has no entry
# for the feature. Mirrors reference/legacy/.../TestFile.pm:89-98.
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

# Static rank table used by rank() to sort tests into an efficient
# run order. Identical across legacy / old2 / current.
my %RANK = (
    smoke      => 1,
    immiscible => 10,
    long       => 20,
    medium     => 50,
    short      => 80,
    isolation  => 100,
);

# Per-attribute defaults. The canonical values live in defaults();
# each accessor below reads its slot from that hashref so a consumer
# that wants to adjust the defaults wholesale can override defaults()
# in one place. defaults() builds a fresh hashref (with fresh mutable
# sub-containers) on every call so consumers never share arrayrefs or
# hashrefs across objects.
sub defaults {
    return {
        min_slots         => 1,
        max_slots         => undef,
        category          => undef,
        duration          => undef,
        stage             => undef,
        conflicts         => [],
        smoke             => 0,
        isolation         => 0,
        retry             => 0,
        retry_isolated    => 0,
        non_perl          => 0,
        is_binary         => 0,
        switches          => [],
        features          => {},
        meta              => {},
        ch_dir            => undef,
        event_timeout     => undef,
        post_exit_timeout => undef,
        comment           => '#',
    };
}

sub json_fields {
    return qw{
        file absolute relative
        min_slots max_slots
        category duration stage
        conflicts
        smoke isolation
        retry retry_isolated
        non_perl is_binary
        switches
        features meta
        ch_dir
        event_timeout post_exit_timeout
        comment
    };
}

# {{{ Per-attribute default accessors
#
# Consuming classes typically install their own (HashBase) slot
# readers that shadow these methods at method-resolution time. The
# default accessors below describe the role contract and serve as a
# fallback for any consumer that does not shadow them; in practice
# they rarely run for a HashBase consumer because the slot reader
# wins. Each one delegates to defaults() so a consumer can override
# every default in a single place by overriding defaults() alone.

sub min_slots         { $_[0]->defaults->{min_slots} }
sub max_slots         { $_[0]->defaults->{max_slots} }
sub category          { $_[0]->defaults->{category} }
sub duration          { $_[0]->defaults->{duration} }
sub stage             { $_[0]->defaults->{stage} }
sub conflicts         { $_[0]->defaults->{conflicts} }
sub smoke             { $_[0]->defaults->{smoke} }
sub isolation         { $_[0]->defaults->{isolation} }
sub retry             { $_[0]->defaults->{retry} }
sub retry_isolated    { $_[0]->defaults->{retry_isolated} }
sub non_perl          { $_[0]->defaults->{non_perl} }
sub is_binary         { $_[0]->defaults->{is_binary} }
sub switches          { $_[0]->defaults->{switches} }
sub features          { $_[0]->defaults->{features} }
sub meta              { $_[0]->defaults->{meta} }
sub ch_dir            { $_[0]->defaults->{ch_dir} }
sub event_timeout     { $_[0]->defaults->{event_timeout} }
sub post_exit_timeout { $_[0]->defaults->{post_exit_timeout} }
sub comment           { $_[0]->defaults->{comment} }

# Cheap helper to read a single key out of the meta hash. Returns the
# list of values stored under that key, or () when missing. Kept as a
# separate name because HashBase consumers shadow meta() with a slot
# reader that does not accept a key argument; meta_get() is unambiguous
# and works whether or not the consumer shadows meta.
sub meta_get {
    my ($self, $key) = @_;
    my $hash = $self->meta // {};
    return () unless defined $key && $hash->{$key};
    return @{$hash->{$key}};
}

# }}} Per-attribute default accessors

# {{{ Derived path helpers + simple predicates

sub absolute      { File::Spec->rel2abs($_[0]->file) }
sub relative      { File::Spec->abs2rel($_[0]->file) }
sub is_executable { -x $_[0]->absolute }
sub has_conflicts { scalar($_[0]->conflicts_list) ? 1 : 0 }

sub feature {
    my ($self, $name) = @_;
    return undef unless defined $name;
    return $self->features->{$name};
}

sub conflicts_list {
    my $self = shift;
    my $c    = $self->conflicts;
    return $c ? @$c : ();
}

# }}} Derived path helpers + simple predicates

# {{{ Pure data lookup helpers
#
# These are pure data lookups -- they never scan the file or mutate
# state. Producers (e.g. App::Yath2::TestFile) populate the underlying
# attributes; the role's helpers turn raw values into the documented
# fallbacks ('medium', 'general', etc.).

sub check_feature {
    my ($self, $name, $default) = @_;
    return $default                     unless defined $name;
    $default = $FEATURE_DEFAULTS{$name} unless defined $default;

    my $features = $self->features // {};
    my $set      = $features->{$name};
    return $default unless defined $set;
    return $set ? 1 : 0;
}

sub check_duration {
    my $self = shift;
    return $self->duration // 'medium';
}

sub check_category {
    my $self = shift;
    return $self->category // 'general';
}

sub check_stage          { $_[0]->stage }
sub check_min_slots      { $_[0]->min_slots }
sub check_max_slots      { $_[0]->max_slots }
sub check_retry          { $_[0]->retry }
sub check_retry_isolated { $_[0]->retry_isolated }

sub rank {
    my $self = shift;
    return $RANK{smoke} if $self->check_feature('smoke');
    return $RANK{$self->check_category} || $RANK{$self->check_duration} || 1;
}

# }}} Pure data lookup helpers

# Tag the JSON payload with the class name so rehydrate() can pick the
# right constructor without a caller-side DEFAULT_CLASS global.
sub TO_JSON {
    my $self = shift;
    my %out  = map { $_ => $self->$_ } $self->json_fields;
    $out{__test_file_class__} = ref($self);
    return \%out;
}

# Reconstruct a TestFile object from a TO_JSON payload. Default
# implementation: strip the class tag and call $class->new with the
# remainder.
#
# absolute and relative are preserved even though they are derived --
# rehydration may happen while reviewing a log on a different host,
# where the file no longer exists and the derivations cannot be
# recomputed. Classes that override may treat those fields as
# authoritative; classes that do not simply ignore the extra
# constructor args.
sub rehydrate {
    my $data = pop;

    croak "rehydrate requires a hashref" unless ref($data) eq 'HASH';

    my %args = %$data;

    my $class = delete $args{__test_file_class__}
        or croak "No rehydration class was present in the data";

    return $class->new(%args);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::TestFile - Role describing the value object the
harness uses to represent a single test file.

=head1 DESCRIPTION

A TestFile object carries everything the scheduler and resource layer need
to make decisions about running a single test: its path(s), slot
requirements, category and duration hints, conflicts, feature toggles,
retry policy, and so on.

This role is the contract. It defines the interface, the per-attribute
defaults, the pure-data lookup helpers (C<check_feature>,
C<check_duration>, etc.), and the JSON serialization story
(C<TO_JSON>/C<rehydrate>). It does B<not> scan files, read shebangs,
parse C<HARNESS-*> directives, mutate state, or perform I/O. Producers
that need to do those things (e.g. L<App::Yath2::TestFile>) live
outside the harness library and consume this role as well.

The only attribute without a sensible default is C<file>; every other
attribute has a default value documented below. Consumers that want
per-instance storage (typically via L<Object::HashBase> + C<init>)
shadow those defaults with their own accessors. The role's own helper
methods go through the accessors -- they never touch C<$self> as a
hash.

=head1 SYNOPSIS

    package My::TestFile;
    use strict;
    use warnings;

    use Object::HashBase qw{
        <file
        <min_slots <max_slots
        <category <duration <stage
        <conflicts
        <smoke <isolation
        <retry <retry_isolated
        <non_perl <is_binary
        <switches
        <features <meta
        <ch_dir
        <event_timeout <post_exit_timeout
        <comment
    };

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::TestFile';

    sub init {
        my $self = shift;
        croak "'file' is required" unless defined $self->{+FILE};
        # Per-instance defaults (shadow the role methods only where the
        # consumer actually allocated a slot for the attribute).
        $self->{+CATEGORY} //= 'general';
        ...
    }

=head1 REQUIRED METHODS

Only C<file> is required. Every other attribute has a default
implementation on the role that returns the documented default; consumers
may shadow those defaults with their own accessors.

=head1 PROVIDED METHODS

=over 4

=item $hashref = $tf->defaults

Return a hashref containing every default that the role's per-attribute
accessors read from. Each call builds a fresh hashref and fresh mutable
sub-containers (empty arrayrefs / hashrefs) so consumers never share
state. Override in a consumer to adjust several defaults in one place
without re-defining each accessor.

=item @fields = $tf->json_fields

Return the ordered list of attribute names that L</TO_JSON> should emit.
Consumers may override to add or remove fields.

=item $path = $tf->absolute

Absolute path, derived via L<File::Spec/rel2abs> from C<file>. Override
if the consumer caches an absolute form.

=item $path = $tf->relative

Relative path, derived via L<File::Spec/abs2rel> from C<file>. Override
if the consumer wants to preserve a caller-supplied relative form.

=item $val = $tf->feature($name)

Shortcut for C<< $tf->features->{$name} >>. Returns C<undef> when the
name is not present or is itself C<undef>.

=item $bool = $tf->check_feature($name, $default?)

Pure data lookup. Returns the boolean (0/1) value of the named feature
when the consumer's data has an entry for it; otherwise returns
C<$default>. When C<$default> is omitted, an internal table provides a
documented fallback (C<timeout>, C<fork>, C<preload>, C<stream>,
C<run>, C<io_events> default to 1; C<isolation> and C<smoke> default
to 0).

This method does B<not> scan the file or mutate state. Consumers that
need scanner-aware behaviour (e.g. forcing C<fork> off for non-perl
tests) should override C<check_feature> in their concrete class or
have the producer pre-populate the data.

=item $duration = $tf->check_duration

Returns the consumer's C<duration> value, or C<'medium'> when undef.

=item $category = $tf->check_category

Returns the consumer's C<category> value, or C<'general'> when undef.

=item $stage = $tf->check_stage

Returns the consumer's C<stage> value (no fallback).

=item $n = $tf->check_min_slots

=item $n = $tf->check_max_slots

Returns the consumer's slot values (no fallback). C<min_slots>
defaults to 1 (per L</defaults>); C<max_slots> defaults to C<undef>,
to be interpreted by each resource ("same as min_slots" or "as many
as are free", per resource).

=item $n = $tf->check_retry

=item $bool = $tf->check_retry_isolated

Returns the consumer's retry settings (no fallback). Both default to
C<0>.

=item @tags = $tf->conflicts_list

Return the conflict tags as a list (not an arrayref). Empty when the
C<conflicts> accessor returns C<undef> or an empty arrayref.

=item $bool = $tf->has_conflicts

True when C<conflicts_list> is non-empty.

=item $bool = $tf->is_executable

True when the file at L</absolute> has the executable bit set.

=item @values = $tf->meta_get($key)

Returns the list of values stored under C<$key> in the C<meta>
hashref, or an empty list when the key is missing. The bare C<meta>
accessor returns the hashref itself; HashBase consumers typically
shadow C<meta> with a plain slot reader, which is why a distinct
helper exists for the key-lookup case.

=item $rank = $tf->rank

Integer used to sort tests into an efficient run order. Lower numbers
sort earlier. Smoke tests always rank 1 (front of the line); otherwise
the rank comes from the category, falling back to the duration, falling
back to 1.

=item $hashref = $tf->TO_JSON

Return a hashref built by reading every name in L</json_fields> via its
accessor, plus a C<__test_file_class__> entry holding the consumer's
package name for later rehydration. The hashref is JSON-ready when every
attribute is itself a JSON scalar, arrayref of scalars, or plain
hashref. Consumers with richer internal structures should override.

=item $tf = rehydrate(\%data)

Reconstruct an object from a L</TO_JSON> payload. The class is taken
from the C<__test_file_class__> field of the payload, not from the
caller -- so this is equivalent to:

    Test2::Harness2::Role::TestFile::rehydrate(\%data);

    # or, ignoring the invocant:
    Whatever->rehydrate(\%data);

Either form picks the class encoded in the data, loads no modules on
its own (the caller is responsible for loading the class first --
L<Test2::Harness2::Run/from_files> does this via
L<Test2::Harness2::Util/load_module>), deletes C<__test_file_class__>
from the args, and calls C<< $class->new(%args) >>.

C<absolute> and C<relative> are preserved even though they are
derived -- rehydration may happen when reviewing a log on a different
machine where the file no longer exists and the derivations cannot
be recomputed. Classes that override C<rehydrate> may treat those
fields as authoritative; classes that do not simply ignore the extra
constructor args.

=back

=head1 ATTRIBUTES

C<file> is required. Every other attribute has a default implementation
on the role; the role does not know how a consumer stores an override.

=over 4

=item file (no sensible default)

Path identifying the test file. Absolute or relative; L</absolute> and
L</relative> both derive from this value.

=item min_slots, max_slots

Slot requirements for C<is_job_limiter> resources. Default
C<min_slots = 1>; C<max_slots> defaults to C<undef>, which each
resource interprets ("same as min_slots", "as many as are free", etc.,
per resource).

=item category, duration, stage

Scheduler hints. Defaults: C<category =E<gt> undef>, C<duration =E<gt>
undef>, C<stage =E<gt> undef>. The raw attributes stay undef until a
producer (e.g. a C<HARNESS-CATEGORY-*> /
C<HARNESS-DURATION-*> / C<HARNESS-STAGE-*> directive scanner)
populates them. C<check_category> and C<check_duration> fall back to
C<'general'> / C<'medium'> respectively when the raw attribute is
still undef.

=item conflicts

Arrayref of conflict tags. Two tests sharing a tag must not run
simultaneously. Default C<[]>.

=item smoke, isolation, retry, retry_isolated, non_perl, is_binary

Integer/boolean classifiers. Default C<0>.

=item switches

Arrayref of perl switches (e.g. from a shebang). Default C<[]>.

=item features

Hashref of feature toggles. Default C<{}>.

=item meta

Hashref of free-form metadata. Default C<{}>.

=item ch_dir

Directory to chdir into before running the test, or C<undef> for none.

=item event_timeout, post_exit_timeout

Idleness timeouts (seconds). Default C<undef>.

=item comment

Comment character used by any directive parser the consumer might build on
top. Default C<'#'>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
