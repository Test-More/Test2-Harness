package Test2::Harness2::Role::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec ();

use Role::Tiny;

# Pluggable default class used by callers that want to promote a bare path
# string or attribute hashref into a TestFile object without knowing which
# concrete class to build. The role itself never constructs anything; this
# variable is only consulted by outside wrappers (e.g. Test2::Harness2::Run).
our $DEFAULT_CLASS;

# Every attribute is an accessor on the consumer. The role does not assume
# any particular storage model, so each accessor is a requirement -- the
# consumer must expose these as methods (e.g. via Object::HashBase).
requires qw{
    file

    min_slots
    max_slots

    category
    duration
    stage

    conflicts

    smoke
    isolation

    retry
    retry_isolated

    non_perl
    is_binary

    switches

    features
    meta

    ch_dir

    event_timeout
    post_exit_timeout

    comment
};

sub defaults {
    return {
        min_slots         => 1,
        max_slots         => undef,
        category          => 'general',
        duration          => 'medium',
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
        file
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

sub absolute { File::Spec->rel2abs($_[0]->file) }
sub relative { File::Spec->abs2rel($_[0]->file) }

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

sub has_conflicts { scalar($_[0]->conflicts_list) ? 1 : 0 }

sub is_executable { -x $_[0]->absolute }

sub TO_JSON {
    my $self = shift;
    return {map { $_ => $self->$_ } $self->json_fields};
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

This role defines the interface without assuming any particular storage
model. Every attribute is a required method; consumers typically expose
them via L<Object::HashBase> but any accessor-style implementation works.
The role's own default methods never access the instance as a hash; they
go through the accessors.

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
        my $defaults = $self->defaults;
        $self->{$_} //= $defaults->{$_} for keys %$defaults;
    }

=head1 REQUIRED METHODS

Every attribute name is required. Consumers must expose each as a method.
See L</ATTRIBUTES> for the list. The role applies C<requires> to each.

=head1 PROVIDED METHODS

=over 4

=item $hashref = $tf->defaults

Return a hashref mapping attribute names to sensible default values. The
hashref is freshly constructed on every call so mutable defaults (empty
arrayrefs and hashrefs) are independent. Consumers typically apply these
in C<init>.

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

=item @tags = $tf->conflicts_list

Return the conflict tags as a list (not an arrayref). Empty when the
C<conflicts> accessor returns C<undef> or an empty arrayref.

=item $bool = $tf->has_conflicts

True when C<conflicts_list> is non-empty.

=item $bool = $tf->is_executable

True when the file at L</absolute> has the executable bit set.

=item $hashref = $tf->TO_JSON

Return a hashref built by reading every name in L</json_fields> via its
accessor. The hashref is JSON-ready when every attribute is itself a JSON
scalar, arrayref of scalars, or plain hashref. Consumers with richer
internal structures should override.

=back

=head1 ATTRIBUTES

Every attribute below is required. The role does not know how they are
stored.

=over 4

=item file (no sensible default)

Path identifying the test file. Absolute or relative; L</absolute> and
L</relative> both derive from this value.

=item min_slots, max_slots

Slot requirements for C<is_job_limiter> resources. Default C<min_slots = 1>;
C<max_slots> defaults to C<undef> (resources interpret as "same as
min_slots" or "as many as are free", per resource).

=item category, duration, stage

Scheduler hints. Defaults: C<category =E<gt> 'general'>, C<duration =E<gt>
'medium'>, C<stage =E<gt> undef>.

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

=head1 PACKAGE VARIABLES

=over 4

=item $Test2::Harness2::Role::TestFile::DEFAULT_CLASS

Optional; a class name used by outside wrappers that want to promote a
bare path string or attribute hashref into a TestFile object. The role
itself never consults this variable; callers such as
L<Test2::Harness2::Run/from_files> do. Leave unset to force callers to
hand in already-constructed role consumers.

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
