use Test2::V0;

__END__

package Test2::Harness::Runner::Preload;
use strict;
use warnings;

our $VERSION = '0.001100';

sub stages { () }
sub fork_stages { () }

sub preload {
    my $class = shift;
    my ($do_not_load, $job_count) = @_;
    die "$class does not override preload()";
}

sub pre_fork {
    my $class = shift;
    my ($job) = @_;
}

sub post_fork {
    my $class = shift;
    my ($job) = @_;
}

sub pre_launch {
    my $class = shift;
    my ($job) = @_;
}


1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preload - Base class for complex preload libraries.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
