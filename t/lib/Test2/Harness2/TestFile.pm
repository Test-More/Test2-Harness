package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    <file

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

use Test2::Harness2::Role::TestFile;
use Role::Tiny::With;
with 'Test2::Harness2::Role::TestFile';

sub init {
    my $self = shift;

    my $file = $self->{+FILE};
    croak "'file' is a required attribute" unless defined $file && length $file;

    # Resolve to an absolute path once so a later chdir does not redirect
    # the launch. The role's ->absolute/->relative methods both derive from
    # this stored value.
    $self->{+FILE} = File::Spec->rel2abs($file)
        unless File::Spec->file_name_is_absolute($file);

    # Fill in per-instance defaults. HashBase accessors shadow the role's
    # default methods, so leaving a slot undef would make the accessor
    # return undef instead of the role default. Set them here so the
    # HashBase accessor returns the documented default when no value was
    # supplied.
    $self->{+MIN_SLOTS}      //= 1;
    $self->{+CATEGORY}       //= 'general';
    $self->{+DURATION}       //= 'medium';
    $self->{+CONFLICTS}      //= [];
    $self->{+SMOKE}          //= 0;
    $self->{+ISOLATION}      //= 0;
    $self->{+RETRY}          //= 0;
    $self->{+RETRY_ISOLATED} //= 0;
    $self->{+NON_PERL}       //= 0;
    $self->{+IS_BINARY}      //= 0;
    $self->{+SWITCHES}       //= [];
    $self->{+FEATURES}       //= {};
    $self->{+META}           //= {};
    $self->{+COMMENT}        //= '#';
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TestFile - Reference implementation of
L<Test2::Harness2::Role::TestFile> used by the test suite.

=head1 DESCRIPTION

A plain value object carrying everything the harness scheduler and resource
layer need to make decisions about a single test file. Consumes
L<Test2::Harness2::Role::TestFile> for its interface; uses
L<Object::HashBase> for storage; fills defaults during C<init> for each
attribute whose HashBase accessor would otherwise shadow the role
default with C<undef>; resolves C<file> to an absolute path.

B<This class lives under C<t/lib>>. It exists for the test suite and for
callers that want a simple drop-in TestFile class; the harness library
itself does not depend on it. A fuller implementation with directive
parsing and file scanning is expected to land later in the rewrite.

=head1 SYNOPSIS

    use lib 't/lib';
    use Test2::Harness2::TestFile;

    my $tf = Test2::Harness2::TestFile->new(
        file      => 't/foo.t',
        min_slots => 1,
        max_slots => 2,
        category  => 'general',
        duration  => 'short',
        conflicts => ['db'],
    );

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
