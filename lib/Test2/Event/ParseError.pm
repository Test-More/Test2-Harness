package Test2::Event::ParseError;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/parse_error/;

sub init {
    my $self = shift;
    defined $self->{+PARSE_ERROR} or $self->trace->throw("'parse_error' is a required attribute");
}

sub causes_fail { 1 }
sub diagnostics { 1 }

sub summary { 'Error parsing output from a test file: ' . $_[0]->{+PARSE_ERROR} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Event::ParseError - Error parsing a test file's output

=head1 DESCRIPTION

This event is generated when there is an error parsing the output from a test
job.

=head1 SYNOPSIS

    use Test2::Event::ParseError;

    return Test2::Event::ParseError->new(parse_error => "Cannot parse this gibberish: $line");

=head1 METHODS

Inherits from L<Test2::Event>. Also defines:

=over 4

=item $error = $e->parse_error

The parsing error message.

=back

The C<causes_fail> and C<diagnostics> methods return true for this event.

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
