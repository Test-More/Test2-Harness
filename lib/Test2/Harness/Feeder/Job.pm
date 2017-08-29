package Test2::Harness::Feeder::Job;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak carp/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness::Job::Dir;

BEGIN { require Test2::Harness::Feeder; our @ISA = ('Test2::Harness::Feeder') }

use Test2::Harness::Util::HashBase qw{
    -_complete

    -job_id
    -run_id
    -dir
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'job_id' is a required attribute"
        unless $self->{+JOB_ID};

    croak "'run_id' is a required attribute"
        unless $self->{+RUN_ID};

    my $dir = $self->{+DIR} or croak "'dir' is a required attribute";
    unless (blessed($dir) && $dir->isa('Test2::Harness::Job::Dir')) {
        croak "'dir' must be a valid directory" unless -d $dir;

        $dir = $self->{+DIR} = Test2::Harness::Job::Dir->new(
            job_root => $dir,
            run_id   => $self->{+RUN_ID},
            job_id   => $self->{+JOB_ID},
        );
    }
}

sub poll {
    my $self = shift;
    my ($max) = @_;

    return if $self->{+_COMPLETE};

    my @events = $self->{+DIR}->poll($max);

    return @events;
}

sub set_complete {
    my $self = shift;

    $self->{+_COMPLETE} = 1;
    delete $self->{+DIR};

    return $self->{+_COMPLETE};
}

sub complete {
    my $self = shift;

    return $self->{+_COMPLETE};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Feeder::Job - Get the feed of events from a running job.

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
