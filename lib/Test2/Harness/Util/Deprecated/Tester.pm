package Test2::Harness::Util::Deprecated::Tester;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Util qw/mod2file/;
use Test2::Tools::Basic qw/ok done_testing/;
use Test2::API qw/context/;

use Test2::Harness::Util::Deprecated();

sub import {
    my $class = shift;
    my ($test_class) = @_;

    my $ctx = context();

    my @out;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @out => @_ };
        require(mod2file($test_class));
        1;
    };
    unshift @out => $@ unless $ok;

    if (grep { m/Module '$test_class' has been deprecated/ } @out) {
        $ctx->pass("Module '$test_class' is properly deprecated")
    }
    else {
        $ctx->fail("Module '$test_class' is properly deprecated")
    }

    $ctx->done_testing;

    $ctx->release;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::Deprecated::Tester - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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

