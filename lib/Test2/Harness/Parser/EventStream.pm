package Test2::Harness::Parser::EventStream;
use strict;
use warnings;

our $VERSION = '0.000014';

use base 'Test2::Harness::Parser';
use Test2::Util::HashBase;

use Test2::Event 1.302068;
use Test2::Event::Bail;
use Test2::Event::Diag;
use Test2::Event::Encoding;
use Test2::Event::Exception;
use Test2::Event::Note;
use Test2::Event::Ok;
use Test2::Event::ParseError;
use Test2::Event::Plan;
use Test2::Event::Skip;
use Test2::Event::Subtest;
use Test2::Event::UnknownStderr;
use Test2::Event::UnknownStdout;
use Test2::Event::Waiting;
use Test2::Harness::JSON;

sub morph { }

sub step {
    my $self = shift;

    return ($self->parse_stderr, $self->parse_stdout);
}

sub parse_stderr {
    my $self = shift;

    my $line = $self->proc->get_err_line or return;
    chomp $line;

    return Test2::Event::UnknownStderr->new(output => $line);
}

sub parse_stdout {
    my $self = shift;

    my $line = $self->proc->get_out_line or return;
    $line =~ s/\s+\z//s;

    if ($line =~ m/^T2_ENCODING: (.+)$/) {
        my $enc = $1;

        $self->proc->encoding($enc);

        return Test2::Event::Encoding->new(
            encoding => $enc,
        );
    }

    if ( my $event  = $self->_event_from_stdout($line) ) {
        return $event;
    }

    return Test2::Event::UnknownStdout->new(output => $line);
}

sub _event_from_stdout {
    my $self = shift;
    my $out = shift;

    return unless $out =~ s/^T2_EVENT:\s//;

    local $@ = undef;
    my $data = eval { JSON->new->decode($out) };
    my $err = $@;

    if ($data) {
        return Test2::Event->from_json(%$data);
    }

    chomp($err);
    return Test2::Event::ParseError->new(parse_error => $err);
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

Anything sent to STDERR will be turned into a L<Test2::Event::UnknownStderr>
object.

=item STDOUT

Anything sent to STDOUT without a prefix, or with an unknown prefix will be
turned into a L<Test2::Event::UnknownStdout> object.

=item T2_ENCODING: ...

A line of STDOUT with this prefix will be used to set the encoding.

=item T2_EVENT: ...JSON...

A line of STDOUT with this prefix will be consumed as JSON and used to
construct an L<Test2::Event> object.

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
