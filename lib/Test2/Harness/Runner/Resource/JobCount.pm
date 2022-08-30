package Test2::Harness::Runner::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '1.000127';

use parent 'Test2::Harness::Runner::Resource';
use Test2::Harness::Util::HashBase qw/<settings <job_count <used/;

sub job_limiter { 1 }

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;
    $self->init();
    return $self;
}

sub init {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    $self->{+JOB_COUNT} //= $settings ? $settings->runner->job_count // 1 : 1;
    $self->{+USED} //= 0;
}

sub job_limiter_max {
    my $self = shift;
    return $self->{+JOB_COUNT};
}

sub job_limiter_at_max {
    my $self = shift;
    return 1 if $self->{+USED} >= $self->{+JOB_COUNT};
    return 0;
}

sub available {
    my $self = shift;
    return 0 if $self->{+USED} >= $self->{+JOB_COUNT};
    return 1;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = 1;
}

sub record {
    my $self = shift;
    $self->{+USED}++;
}

sub release {
    my $self = shift;
    $self->{+USED}--;
}

sub status_lines {
    my $self = shift;

    return ("using $self->{+USED}/$self->{+JOB_COUNT} job slot(s).");
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::JobCount - limit the job count (-j)

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
