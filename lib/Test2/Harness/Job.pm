package Test2::Harness::Job;
use strict;
use warnings;

our $VERSION = '0.001075';

use Carp qw/croak/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    -job_id
    -job_name

    -pid

    -file
    -env_vars
    -libs
    -switches
    -args
    -input
    -times
    -show_times
    -load
    -load_import
    -preload
    -ch_dir

    -event_uuids
    -mem_usage

    -use_fork
    -use_stream
    -use_timeout

    -event_timeout
    -postexit_timeout
};

sub init {
    my $self = shift;

    croak "The 'job_id' attribute is required"
        unless $self->{+JOB_ID};

    croak "The 'file' attribute is required"
        unless $self->{+FILE};

    $self->{+JOB_NAME} ||= $self->{+JOB_ID};

    $self->{+ENV_VARS} ||= {};
    $self->{+LIBS}     ||= [];
    $self->{+SWITCHES} ||= [];
    $self->{+ARGS}     ||= [];
    $self->{+INPUT}    ||= '';

    $self->{+USE_FORK}    = 1 unless defined $self->{+USE_FORK};
    $self->{+USE_STREAM}  = 1 unless defined $self->{+USE_STREAM};
    $self->{+USE_TIMEOUT} = 1 unless defined $self->{+USE_TIMEOUT};
}

sub TO_JSON { return { %{$_[0]} } }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job - Representation of a test job.

=head1 DESCRIPTION

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
