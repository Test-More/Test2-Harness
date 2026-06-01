package App::Yath::Script::V2;
use v5.38;

our $VERSION = '2.000000';

use App::Yath2;

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V2 - Version-2 entry point for the C<yath> script.

=head1 DESCRIPTION

The external C<App::Yath::Script> module (which the C<yath> script loads) does
version discovery, then delegates to an C<App::Yath::Script::V#> module. This is
the version-2 implementation: it builds an L<App::Yath2> instance during the
C<BEGIN> phase and runs it at runtime.

This distribution ships no C<yath> binary of its own; it provides this delegate
so the installed C<yath> script can drive the 2.0 harness.

=head1 SYNOPSIS

    # Invoked by App::Yath::Script, not directly:
    App::Yath::Script::V2->do_begin(script => $path, argv => \@ARGV, ...);
    exit(App::Yath::Script::V2->do_runtime);

=cut

my $INSTANCE;

=head1 PUBLIC METHODS

=cut

=over 4

=item $class->do_begin(script => $path, argv => \@argv, config => $f, user_config => $f)

Called during C<BEGIN> by L<App::Yath::Script>. Constructs the L<App::Yath2>
instance from the discovered script path, argument list, and rc-file paths.

=item $exit = $class->do_runtime

Called after C<BEGIN>. Runs the app and returns its exit code.

=back

=cut

sub do_begin ($class, %params) {
    $INSTANCE = App::Yath2->new(
        script      => $params{script},
        args        => $params{argv} // [],
        config      => $params{config},
        user_config => $params{user_config},
    );

    return;
}

sub do_runtime ($class) {
    return $INSTANCE->run;
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
