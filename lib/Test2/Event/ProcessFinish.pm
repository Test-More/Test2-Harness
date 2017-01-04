package Test2::Event::ProcessFinish;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/file result/;

sub init {
    my $self = shift;
    defined $self->{+RESULT} or $self->trace->throw("'result' is a required attribute");
}

sub summary {
    my $self    = shift;
    my $summary = $self->{+FILE} . ' ';
    if ($self->{+RESULT}->ran_tests) {
        return $summary . ($self->{+RESULT}->passed ? 'passed' : 'failed');
    }
    else {
        return $summary . 'did not run any tests';
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Event::ProcessFinish - A test process has finished

=head1 DESCRIPTION

This event is generated when the test harness sees that a test process has
exited.

=head1 SYNOPSIS

    use Test2::Event::ProcessFinish;

    return Test2::Event::ProcessFinish->new(file => $file, result => 42);

=head1 METHODS

Inherits from L<Test2::Event>. Also defines:

=over 4

=item $file = $e->file

The test file that was being executed.

=item $result = $e->result

The L<Test2::Harness::Result> object for the process.

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
