package Test2::Plugin::Immiscible;
use strict;
use warnings;

use Test2::API qw/context/;

our $VERSION = '2.000005';

our $LOCK;

sub import {
    my $class = shift;
    my ($skip_cb) = @_;

    my $ctx = context();

    if ($skip_cb && $skip_cb->()) {
        $ctx->note("Immiscibility enforcement skipped due to callback.");
    }
    else {
        if (-w '.') {
            if (open($LOCK, '>>', './.immiscible-test.lock')) {
                require Fcntl;
                if (flock($LOCK, Fcntl::LOCK_EX())) {
                    $ctx->note("Immiscibility enforcement success.");
                }
                else {
                    $ctx->plan(0, SKIP => "could not get lock '$!', cannot guarentee immiscibility.");
                }
            }
            else {
                $ctx->plan(0, SKIP => "could not get lock '$!', cannot guarentee immiscibility.");
            }
        }
        else {
            $ctx->plan(0, SKIP => "'.' is not writable, cannot guarentee immiscibility.");
        }
    }

    $ctx->release;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Plugin::Immiscible - Prevent tests with this module from running
together in the same test suite.

=head1 DESCRIPTION

Prevent any 2 tests with this module loaded from running together in the same
repo.

=head1 SYNOPSIS

    use Test2::Plugin::Immiscible;

or

    Test2::Plugin::Immiscible(sub { $ENV{SKIP_IMMISCIBILITY_CHECK } ? 1 : 0 );

The second form allows you to skip the protection if certain conditions are
met. The callback sub should return true if the protection should be skipped.

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
