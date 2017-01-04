package Test2::Event::ParserSelect;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/parser_class/;

sub init {
    my $self = shift;
    defined $self->{+PARSER_CLASS} or $self->trace->throw("'parser_class' is a required attribute");
}

sub summary { 'Selected ' . $_[0]->{+PARSER_CLASS} . ' for parsing' }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Event::ParserSelect - A parser was select based on a test job's output

=head1 DESCRIPTION

This event is generated when the L<Test2::Harness::Parser> class automatically
selects a parser for a test job based on that job's output.

=head1 SYNOPSIS

    use Test2::Event::ParserSelect;

    return Test2::Event::ParserSelect->new(parser_class => 'Test2::Harness::Parser::EventStream');

=head1 METHODS

Inherits from L<Test2::Event>. Also defines:

=over 4

=item $class = $e->parser_class

The parser class that was selected.

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
