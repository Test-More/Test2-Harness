package Test2::Harness::State::Instance;
use strict;
use warnings;

our $VERSION = '1.000152';

use Carp qw/confess/;

use parent 'Test2::Harness::IPC::SharedState';
use Test2::Harness::Util::HashBase(
    qw{
        <resources
        <job_count
        <settings
        <workdir
        <plugins
        <runs
        <ipc_model
        <jobs
        <queue
    },
);

sub init_state {
    my $class = shift;
    my ($state, $data) = @_;

    $data->{+WORKDIR}  //= $state->{workdir}  // confess "No workdir";
    $data->{+SETTINGS} //= $state->{settings} // confess "No settings";
    my $settings = $data->{settings};

    $data->{+JOBS}      //= {};
    $data->{+QUEUE}     //= {};
    $data->{+IPC_MODEL} //= {};
    $data->{+JOB_COUNT} //= $state->{job_count} // $settings->check_prefix('runner') ? $settings->runner->job_count // 1 : 1;

    for my $type (qw/resource plugin renderer/) {
        my $plural = "${type}s";
        my $raw;

        if ($type eq 'resource') {
            next unless $settings->check_prefix('runner');
            $raw  = $settings->runner->$plural // [];
            @$raw = sort { $a->sort_weight <=> $b->sort_weight } @$raw;
        }
        else {
            next unless $settings->check_prefix('harness');
            next unless $settings->harness->check_field($plural);
            $raw = $settings->harness->$plural // [];
        }

        $data->{$plural} = [map { ref($_) || $_ } @$raw];
    }

    return bless($data, $class);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::State::Instance - Data structure for yath shared state

=head1 DESCRIPTION

This is the primary shared state for all processes participating in a yath
instance.

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
