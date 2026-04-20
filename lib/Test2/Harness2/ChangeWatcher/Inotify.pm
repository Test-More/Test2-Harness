package Test2::Harness2::ChangeWatcher::Inotify;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util qw/clean_path/;

# Optional dependency: we compile without it but refuse to run.
# Gate via a constant per the project's style ("use constant for
# 'is module installed' gating").
use constant HAS_INOTIFY => eval { require Linux::Inotify2; 1 };

use Object::HashBase qw{
    +inotify
    <watches
    <watched
    <pending
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::ChangeWatcher';

sub viable { HAS_INOTIFY ? 1 : 0 }

sub init {
    my $self = shift;

    croak "Linux::Inotify2 is not installed; use Test2::Harness2::ChangeWatcher::Stat instead"
        unless HAS_INOTIFY;

    $self->{+WATCHES} //= {};
    $self->{+WATCHED} //= {};
    $self->{+PENDING} //= {};

    my $inotify = Linux::Inotify2->new
        or croak "Linux::Inotify2->new failed: $!";

    # Make poll non-blocking so changed_files can be called off a
    # tick without stalling the service loop.
    $inotify->blocking(0);
    $self->{+INOTIFY} = $inotify;
}

sub watch {
    my $self = shift;
    my ($file, $val) = @_;

    croak "watch() requires a file (got: " . (defined $file ? "'$file'" : '(undef)') . ")"
        unless defined $file && length $file;

    $file = clean_path($file);

    croak "watch() requires '$file' to exist"
        unless -e $file;

    $val //= 1;
    $self->{+WATCHES}->{$file} = $val;

    my $pending = $self->{+PENDING};
    my $watch   = $self->{+INOTIFY}->watch(
        $file,
        Linux::Inotify2::IN_MODIFY() | Linux::Inotify2::IN_ATTRIB() | Linux::Inotify2::IN_CLOSE_WRITE() | Linux::Inotify2::IN_MOVE_SELF() | Linux::Inotify2::IN_DELETE_SELF(),
        sub { $pending->{$file} = 1 },
    );

    $self->{+WATCHED}->{$file} = $watch;

    return $val;
}

sub changed_files {
    my $self = shift;

    # Poll. Non-blocking because of the init() call; returns 0 when
    # there were no events, a positive count otherwise. Either way
    # the callbacks we registered in watch() populate $self->{+PENDING}.
    $self->{+INOTIFY}->poll;

    my @files = sort keys %{$self->{+PENDING}};
    $self->{+PENDING} = {};

    return \@files;
}

sub stop {
    my $self = shift;
    $self->{+WATCHED} = {};
    $self->{+WATCHES} = {};
    $self->{+PENDING} = {};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::ChangeWatcher::Inotify - Kernel-level change
watcher for the preload reloader (Linux + L<Linux::Inotify2>).

=head1 DESCRIPTION

Each watched file becomes an L<Linux::Inotify2> watch that fires on
C<IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVE_SELF | IN_DELETE_SELF>.
Events accumulate asynchronously; C<changed_files> non-blockingly
polls the inotify fd and returns the files whose events have landed
since the last call.

Gated via C<HAS_INOTIFY> (constant): the module compiles without
L<Linux::Inotify2> so consumers can conditionally use it. Calling
C<new> without the dep installed dies with a clear error; consumers
should consult L</viable> first.

=head1 WHY INOTIFY

Cheap to watch many files, delivered by the kernel without polling
the filesystem on a tick. The L<Stat
fallback|Test2::Harness2::ChangeWatcher::Stat> is the portable
alternative when this backend's dep isn't available.

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
