package Test2::Harness::Job;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    -job_id

    -pid

    -file
    -env_vars
    -libs
    -switches
    -args
    -input
    -no_stream
    -no_fork
};

sub init {
    my $self = shift;

    croak "The 'job_id' attribute is required"
        unless $self->{+JOB_ID};

    croak "The 'file' attribute is required"
        unless $self->{+FILE};

    $self->{+ENV_VARS} ||= {};
    $self->{+LIBS}     ||= [];
    $self->{+SWITCHES} ||= [];
    $self->{+ARGS}     ||= [];
    $self->{+INPUT}    ||= '';
}

sub TO_JSON { return { %{$_[0]} } }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job - Representation of a test job.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
