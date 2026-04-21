package App::Yath::Script::V2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use App::Yath::Script qw/clean_path/;

my %BEGIN_PARAMS;

# Called during BEGIN by App::Yath::Script, once it has picked this
# version handler. We just capture the dispatcher's parameters for
# do_runtime() to consume; heavy lifting happens at runtime so that
# a test harness can stub this module in unit tests.
sub do_begin {
    my $class  = shift;
    my %params = @_;

    %BEGIN_PARAMS = %params;
    return;
}

sub do_runtime {
    my $class = shift;

    my $script = $BEGIN_PARAMS{script};
    my $argv   = $BEGIN_PARAMS{argv} // [];

    return $class->run(
        script      => $script,
        argv        => $argv,
        config      => $BEGIN_PARAMS{config},
        user_config => $BEGIN_PARAMS{user_config},
    );
}

sub run {
    my $class  = shift;
    my %params = @_;

    require App::Yath2;
    my $app = App::Yath2->new(
        script      => $params{script},
        argv        => $params{argv} // [],
        config      => $params{config},
        user_config => $params{user_config},
    );

    return $app->run;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V2 - V2 entry point for App::Yath::Script.

=head1 DESCRIPTION

This module is the V2 implementation of the versioned yath script
handler contract defined by
L<App::Yath::Script|App::Yath::Script> (from the C<App-Yath-Script>
distribution). When the shared C<yath> launcher sees a C<# V2>
marker in C<.yath.rc> (or no config at all but this module is the
highest-numbered installed V{N}), C<App::Yath::Script> loads this
module and hands off control via L</do_begin> and L</do_runtime>.

This module itself is a thin wrapper: it captures the dispatcher's
parameters at C<BEGIN> time and, at runtime, instantiates
L<App::Yath2> and calls its C<run> method.

=head1 METHODS

=over 4

=item $class->do_begin(script => $s, argv => \@argv, config => $c, user_config => $u)

Called during C<BEGIN> by C<App::Yath::Script>. Records the inbound
parameters for L</do_runtime> to consume.

=item $exit = $class->do_runtime()

Called post-C<BEGIN> by C<App::Yath::Script>. Delegates to L</run>
with the parameters captured in L</do_begin>. Returns the exit code
the process should exit with.

=item $exit = $class->run(script => $s, argv => \@argv, config => $c, user_config => $u)

Direct entry point bypassing C<App::Yath::Script>. Useful for unit
tests and embedded callers. Loads L<App::Yath2>, constructs the app
object, and calls its C<run> method.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
