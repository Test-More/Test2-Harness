package Test2::Event::UnknownStderr;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/output/;

sub init {
    my $self = shift;
    defined $self->{+OUTPUT} or $self->trace->throw("'output' is a required attribute");
}

sub diagnostics { 1 }

sub summary { $_[0]->{+OUTPUT} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Event::UnknownStderr - Parser saw unexpected output on C<STDERR>

=head1 DESCRIPTION

This event is generated when a parser sees unexpected output on the C<STDERR>
handle.

=head1 SYNOPSIS

    use Test2::Event::UnknownStderr;

    return Test2::Event::UnknownStderr->new(output => $line);

=head1 METHODS

Inherits from L<Test2::Event>. Also defines:

=over 4

=item $output = $e->output

The output that was seen.

=back

The C<diagnostics> method returns true for this event.

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
