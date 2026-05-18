package App::Yath2::Concluder;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <log
    <settings
    <out_fh
};

sub init {
    my $self = shift;
    croak "'log' is required" unless defined $self->{+LOG};
    $self->{+OUT_FH} //= \*STDOUT;
    return;
}

sub run { croak ref($_[0]) . " must implement run()" }

# Async opt-in slot. Concluders run sequentially and synchronously by
# default in the parent process after all renderer children reap. A
# concluder can set this to 1 in a subclass to indicate that a future
# async dispatcher may run it in the background; the v1 dispatcher
# ignores the flag and runs everything synchronously.
sub async { 0 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Concluder - Base class for end-of-run concluders.

=head1 DESCRIPTION

Concluders run sequentially in the parent process after all renderer
children reap. They read the Log directly via the producer descriptor
iteration API (C<run_producers>, C<job_producers>, etc.) and emit
summaries, send notifications, or perform other terminal-side cleanup
actions.

Concluders are not renderers: they do not stream output during the run,
do not run in a forked child process, and do not consume the event
stream. They are invoked exactly once at the end of the run.

=head1 SUBCLASSING

Subclasses must override C<run> and may override C<async>. Construction
fields:

=over 4

=item C<log>

The L<App::Yath2::Log> instance to read. Required.

=item C<settings>

The full yath settings object. Optional; concluders that consult their
own option group's settings should accept it.

=item C<out_fh>

The output filehandle. Defaults to C<\*STDOUT>.

=back

=head1 METHODS

=over 4

=item $c->run

Perform the concluder's action. Must be overridden by subclasses. The
default implementation croaks.

=item $c->async

Returns false. Reserved for a future async dispatch slot. The v1
dispatcher runs every concluder synchronously.

=back

=head1 SEE ALSO

L<App::Yath2::Concluder::Summary>,
L<App::Yath2::Concluder::Notify>,
L<App::Yath2::Concluder::ResetTerm>,
L<App::Yath2::Options::Concluder>.

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
