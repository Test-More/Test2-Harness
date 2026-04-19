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

# Register this class as the default string/hash-rehydration target for any
# harness code that wants a concrete class without hard-coding one. Only set
# the slot when nothing else has claimed it, so explicit caller overrides
# still win.
$Test2::Harness2::Role::TestFile::DEFAULT_CLASS //= __PACKAGE__;

sub init {
    my $self = shift;

    my $file = $self->{+FILE};
    croak "'file' is a required attribute" unless defined $file && length $file;

    # Resolve to an absolute path once so a later chdir does not redirect
    # the launch. The role's ->absolute/->relative methods both derive from
    # this stored value.
    $self->{+FILE} = File::Spec->rel2abs($file)
        unless File::Spec->file_name_is_absolute($file);

    my $defaults = $self->defaults;
    for my $key (keys %$defaults) {
        $self->{$key} //= $defaults->{$key};
    }
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
L<Object::HashBase> for storage; fills in defaults from C<< $self->defaults >>
during construction and resolves C<file> to an absolute path.

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

=head1 SIDE EFFECTS ON LOAD

Loading this module sets
C<$Test2::Harness2::Role::TestFile::DEFAULT_CLASS> to this package if
nothing else has claimed it. Callers that wrap path strings or hashrefs
(e.g. L<Test2::Harness2::Run/from_files>) consult that variable. Tests
that want wrapping should C<use lib 't/lib'; use Test2::Harness2::TestFile>
before calling those wrappers.

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
