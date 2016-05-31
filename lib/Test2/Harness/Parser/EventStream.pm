package Test2::Harness::Parser::EventStream;
use strict;
use warnings;

our $VERSION = '0.000008';

use Test2::Harness::Result;
use Test2::Harness::Fact;

use base 'Test2::Harness::Parser';
use Test2::Util::HashBase;

sub morph { }

sub step {
    my $self = shift;

    my @facts;
    push @facts => $self->parse_stderr;
    push @facts => $self->parse_stdout;

    return @facts;
}

sub parse_stderr {
    my $self = shift;

    my $line = $self->proc->get_err_line or return;
    chomp(my $out = $line);

    return Test2::Harness::Fact->new(
        output             => $out,
        parsed_from_handle => 'STDERR',
        parsed_from_string => $line,
        diagnostics        => 1,
    );
}

sub parse_stdout {
    my $self = shift;

    my $line = $self->proc->get_out_line or return;
    chomp(my $out = $line);
    $out =~ s/[\r\s]+$//g;

    if ($out =~ m/^T2_ENCODING: (.+)$/) {
        my $enc = $1;

        $self->proc->encoding($enc);

        return Test2::Harness::Fact->new(
            encoding           => $enc,
            parsed_from_handle => 'STDOUT',
            parsed_from_string => $line,
        );
    }

    my @facts = Test2::Harness::Fact->from_string($out, parsed_from_handle => 'STDOUT');

    return Test2::Harness::Fact->new(
        output             => $out,
        parsed_from_handle => 'STDOUT',
        parsed_from_string => $line,
        diagnostics        => 0,
    ) unless @facts;

    return @facts;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Parser::EventStream - EventStream parser

=head1 DESCRIPTION

This is the parser counterpart to L<Test2::Formatter::EventStream>. This will
read a stream of output from the test which should include L<Test2::Event>
objects serialized into JSON format.

=head1 STREAM COMPOSITION

=over 4

=item STDERR

Anything sent to STDERR will be turned into a basic diagnostics
L<Test2::Harness::Fact> object.

=item STDOUT

Anything sent to STDOUT without a prefix, or with an unknown prefix will be
turned into a basic L<Test2::Harness::Fact> object.

=item T2_ENCODING: ...

A line of STDOUT with this prefix will be used to set the encoding.

=item T2_EVENT: ...JSON...

A line of STDOUT with this prefix will be consumed as JSON and used to
construct an L<Test2::Event::Fact> object.

=back

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
