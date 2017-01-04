package Test2::Event::UnexpectedProcessExit;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/error file/;

sub init {
    my $self = shift;
    defined $self->{+ERROR} or $self->trace->throw("'error' is a required attribute");
    defined $self->{+FILE} or $self->trace->throw("'file' is a required attribute");
}

sub diagnostics { 1 }

sub summary { $_[0]->{+ERROR} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Event::UnexpectedProcessExit - A test process has finished

=head1 DESCRIPTION

This event is generated when the test harness sees that a test process has
exited.

=head1 SYNOPSIS

    use Test2::Event::UnexpectedProcessExit;

    return Test2::Event::UnexpectedProcessExit->new(file => $file, error => '...');

=head1 METHODS

Inherits from L<Test2::Event>. Also defines:

=over 4

=item $file = $e->file

The test file that was being executed.

=item $error = $e->error

The error message provided to the constructor. This will be 

=back

=head1 SOURCE

The source code repository for Test2::Harness can be found at
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

Copyright 2016 Chad Granum E<lt>exodist@cpan.orgE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
