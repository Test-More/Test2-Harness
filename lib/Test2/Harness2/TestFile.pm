package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    <file
    +relative

    <min_slots
    <max_slots

    <category
    <duration
    <stage

    <conflicts

    <smoke
    <isolation

    <retry
    <retry_isolated

    <non_perl
    <is_binary

    <switches

    <features
    <meta

    <ch_dir

    <event_timeout
    <post_exit_timeout

    <comment
};

sub init {
    my $self = shift;

    my $file = $self->{+FILE};
    croak "'file' is a required attribute" unless defined $file && length $file;

    # Callers may hand us either shape; classify by File::Spec and fill the
    # other slot.
    if (File::Spec->file_name_is_absolute($file)) {
        $self->{+RELATIVE} //= File::Spec->abs2rel($file);
    }
    else {
        $self->{+RELATIVE} //= $file;
        $self->{+FILE} = File::Spec->rel2abs($file);
    }

    $self->{+MIN_SLOTS} //= 1;
    $self->{+MAX_SLOTS} //= $self->{+MIN_SLOTS};

    $self->{+CATEGORY} //= 'general';
    $self->{+DURATION} //= 'medium';

    $self->{+CONFLICTS} //= [];
    $self->{+SWITCHES}  //= [];
    $self->{+FEATURES}  //= {};
    $self->{+META}      //= {};

    $self->{+SMOKE}          //= 0;
    $self->{+ISOLATION}      //= 0;
    $self->{+RETRY}          //= 0;
    $self->{+RETRY_ISOLATED} //= 0;
    $self->{+NON_PERL}       //= 0;
    $self->{+IS_BINARY}      //= 0;

    $self->{+COMMENT} //= '#';
}

sub relative {
    my $self = shift;
    return $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});
}

sub feature {
    my ($self, $name) = @_;
    return undef unless defined $name;
    return $self->{+FEATURES}->{$name};
}

sub conflicts_list { $_[0]->{+CONFLICTS} // [] }

sub has_conflicts {
    my $self = shift;
    return scalar @{$self->conflicts_list} ? 1 : 0;
}

sub is_executable {
    my $self = shift;
    return -x $self->{+FILE};
}

sub TO_JSON {
    my $self = shift;
    my %copy = %$self;
    $copy{+CONFLICTS} = [@{$copy{+CONFLICTS} // []}];
    $copy{+SWITCHES}  = [@{$copy{+SWITCHES}  // []}];
    $copy{+FEATURES}  = {%{$copy{+FEATURES}  // {}}};
    $copy{+META}      = {%{$copy{+META}      // {}}};
    return \%copy;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TestFile - Lightweight description of a test file to be run.

=head1 DESCRIPTION

A plain value object carrying everything the harness scheduler and resource
layer need to make decisions about a single test file: path(s), slot
requirements, category and duration hints, conflict set, features, and
retry policy.

B<This class does not scan files.> The original yath/harness TestFile had
a heavy scanner that parsed C<HARNESS-*> comment directives at the top of
each test. In the 2.0 rewrite that discovery work is the caller's
responsibility -- whoever enqueues a run is expected to hand the harness
service C<TestFile> objects that already have the relevant attributes
set. C<init> fills in safe defaults for anything the caller omitted.

=head1 SYNOPSIS

    use Test2::Harness2::TestFile;

    my $tf = Test2::Harness2::TestFile->new(
        file      => '/abs/path/to/t/foo.t',
        min_slots => 1,
        max_slots => 2,
        category  => 'general',
        duration  => 'short',
        conflicts => ['db'],
    );

=head1 ATTRIBUTES

=over 4

=item file (required)

Absolute path to the test file. A relative path will be resolved against
the current directory at construction time so a later C<chdir> does not
redirect the launch.

=item relative

Relative path, used for display. Derived from C<file> on demand if not
supplied.

=item min_slots / max_slots

Job-slot requirements. Default C<min_slots = 1>, C<max_slots = min_slots>.
Resources interpreting slot counts may treat C<max_slots E<lt>= 0> as
"as many as are free".

=item category

Scheduler bucket: C<general>, C<isolation>, C<immiscible>, etc. Default
C<general>.

=item duration

Scheduler priority hint: C<short>, C<medium>, C<long>. Default C<medium>.

=item stage

Preload stage the test wants to run inside, or C<undef> for any.

=item conflicts

Arrayref of conflict tags. Two tests sharing a tag will not run
simultaneously.

=item smoke / isolation

Bool flags mirroring C<HARNESS-SMOKE> / C<HARNESS-ISOLATION> semantics.

=item retry / retry_isolated

Retry policy integers.

=item features

Arbitrary hashref of feature flags (fork, preload, stream, timeout, run,
etc.). The harness consults specific keys directly; callers may stuff
whatever else is meaningful to their plugins.

=item meta

Hashref of arrayrefs for free-form metadata (mirrors C<HARNESS-META>).

=item switches

Arrayref of perl switches parsed from a shebang line, if any.

=item non_perl / is_binary

Classifiers for non-perl or binary tests.

=item ch_dir

Directory the test should run from, if non-default.

=item event_timeout / post_exit_timeout

Timeouts (in seconds) for event and post-exit idleness.

=item comment

Comment character used when the caller parsed harness directives. Default
C<#>.

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
