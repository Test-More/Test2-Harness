package App::Yath::Script::V2;
use v5.38;

our $VERSION = '2.000000';

use App::Yath2;

my %BEGIN_PARAMS;

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V2 - V2 script hook for App::Yath2

=head1 DESCRIPTION

Implements the C<App::Yath::Script::V{X}> interface expected by
L<App::Yath::Script>. C<do_begin> captures the parameters passed during
the C<BEGIN> phase; C<do_runtime> hands off to L<App::Yath2> for
command dispatch.

=head1 SYNOPSIS

    # Invoked automatically by the yath script via App::Yath::Script.
    # Not called directly by user code.

=cut

=head1 PUBLIC METHODS

=over 4

=item $class->do_begin(%params)

Called by C<App::Yath::Script> during the C<BEGIN> phase. Stores C<script>,
C<argv>, C<config>, and C<user_config> for use at runtime.

=cut

sub do_begin ($class, %params) {
    %BEGIN_PARAMS = %params;
    return;
}

=item $exit = $class->do_runtime()

Called by C<App::Yath::Script> at runtime. Dispatches the stored C<argv>
to L<App::Yath2/run> and returns the exit code.

=back

=cut

sub do_runtime ($class) {
    my $argv = $BEGIN_PARAMS{argv} // [@ARGV];
    return App::Yath2->run(@$argv);
}

1;

__END__

=pod

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
