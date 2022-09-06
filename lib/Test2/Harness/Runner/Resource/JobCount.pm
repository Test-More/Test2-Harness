package Test2::Harness::Runner::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '1.000130';

use parent 'Test2::Harness::Runner::Resource';
use Test2::Harness::Util::HashBase qw/<settings <job_count <used <free/;

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
    $self->{+USED} //= {};
    $self->{+FREE} //= [1 .. $self->{+JOB_COUNT}];
}

sub job_limiter_max {
    my $self = shift;
    return $self->{+JOB_COUNT};
}

sub job_limiter_at_max {
    my $self = shift;
    return 0 if @{$self->{+FREE}};
    return 1;
}

sub available {
    my $self = shift;
    return 1 if @{$self->{+FREE}};
    return 0;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = {
        slot => $self->{+FREE}->[0],
        file => $task->{file},
    };
}

sub record {
    my $self = shift;
    my ($job_id, $info) = @_;

    my $slot = $info->{slot};
    my $file = $info->{file};

    my $check = shift @{$self->{+FREE}};
    die "$0 - check and slot mismatch! ($check vs $slot)" unless $check == $slot;
    $self->{+USED}->{$job_id} = [$slot, $file];
}

sub release {
    my $self = shift;
    my ($job_id) = @_;

    # Could be a free with no used slot.
    my $info = delete $self->{+USED}->{$job_id} or return;
    my ($slot) = @$info;
    push @{$self->{+FREE}} => $slot;
}

sub status_lines {
    my $self = shift;

    my $out = "  Job Slots:\n";

    my %map = map {$_ => "FREE"} @{$self->{+FREE}};
    for my $job_id (keys %{$self->{+USED}}) {
        my $info = $self->{+USED}->{$job_id};
        my ($slot, $file) = @$info;
        $map{$slot} = "$job_id | $file";
    }

    for my $slot (sort keys %map) {
        $out .= "    $slot: $map{$slot}\n";
    }

    return $out;
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
