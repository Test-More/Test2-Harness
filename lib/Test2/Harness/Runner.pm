package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::IPC::Util qw/start_collected_process/;

use Test2::Harness::TestSettings;

use Test2::Harness::Util::HashBase qw{
    <test_settings
    <terminated
    <workdir
    <is_daemon
};

sub ready { 1 }

sub init {
    my $self = shift;

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};

    my $ts = $self->{+TEST_SETTINGS} or croak "'test_settings' is a required attribute";
    unless (blessed($ts)) {
        my $class = delete $ts->{class} // 'Test2::Harness::TestSettings';
        $self->{+TEST_SETTINGS} = $class->new(%$ts);
    }
}

sub blacklist {}
sub overall_status {}
sub process_list {}

sub stages { ['NONE'] }
sub stage_sets { [['NONE', 'NONE']] }

sub job_stage { 'NONE' }

sub start  { }
sub stop   { }
sub abort  { }
sub reload { 0 }

sub kill { $_[0]->terminate('kill') }

sub job_update { }

sub job_launch_data {
    my $self = shift;
    my ($run, $job, $env, $skip) = @_;

    my $run_id = $run->{run_id};

    my $ts = Test2::Harness::TestSettings->merge(
        $self->{+TEST_SETTINGS},
        $run->test_settings,
        $job->test_file->test_settings
    );

    $ts->set_env_vars(%$env) if keys %$env;

    my $workdir = $self->{+WORKDIR};

    return (
        workdir       => $self->{+WORKDIR},
        run           => $run->data_no_jobs,
        skip          => $skip,
        job           => $job,
        test_settings => $ts,
        root_pid      => $$,
        setsid        => 1,
    );
}

sub skip_job {
    my $self = shift;
    my ($run, $job, $env, $skip) = @_;

    $skip //= "Unknown reason";

    return 1 if eval { start_collected_process($self->job_launch_data($run, $job, $env, $skip)); 1 };
    warn $@;
    return 0;
}

sub launch_job {
    my $self = shift;
    my ($stage, $run, $job, $env) = @_;

    croak "Invalid stage '$stage'" unless $stage eq 'NONE';

    return 1 if eval { start_collected_process($self->job_launch_data($run, $job, $env)); 1 };
    warn $@;
    return 0;
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;

    $reason ||= 1;

    return $self->{+TERMINATED} ||= $reason;
}

sub DESTROY {
    my $self = shift;

    $self->terminate('DESTROY');
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

