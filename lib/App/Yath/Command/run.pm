package App::Yath::Command::run;
use strict;
use warnings;

our $VERSION = '0.001009';

use Test2::Harness::Feeder::Run;
use Test2::Harness::Util::File::JSON;

use App::Yath::Util qw/find_pfile/;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase qw/-_feeder -_runner -_pid/;

sub group { 'persist' }

sub has_jobs        { 1 }
sub has_runner      { 0 }
sub has_logger      { 1 }
sub has_display     { 1 }
sub manage_runner   { 0 }
sub always_keep_dir { 1 }

sub summary { "Run tests using the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
foo bar baz
    EOT
}

sub run {
    my $self = shift;

    $self->pre_run();

    my $settings = $self->{+SETTINGS};
    my @search = @{$settings->{search}};

    my $pfile = find_pfile()
        or die "Could not find " . $self->pfile_name . " in current directory, or any parent directories.\n";

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $data->{dir},
        pid => $data->{pid},
    );

    my $run = $runner->run;

    my $queue = $runner->queue;

    $run->{search} = \@search;

    my %jobs;
    my $base_id = 1;
    for my $tf ($self->make_run_from_settings->find_files) {
        my $job_id = $$ . '-' . $base_id++;

        my $item = $tf->queue_item($job_id);

        $item->{args}        = $settings->{pass}        if defined $settings->{pass};
        $item->{times}       = $settings->{times}       if defined $settings->{times};
        $item->{use_stream}  = $settings->{use_stream}  if defined $settings->{use_stream};
        $item->{load}        = $settings->{load}        if defined $settings->{load};
        $item->{load_import} = $settings->{load_import} if defined $settings->{load_import};
        $item->{env_vars}    = $settings->{env_vars}    if defined $settings->{env_vars};
        $item->{input}       = $settings->{input}       if defined $settings->{input};
        $item->{chdir}       = $settings->{chdir}       if defined $settings->{chdir};

        $queue->enqueue($item);
        $jobs{$job_id} = 1;
    }

    my $feeder = Test2::Harness::Feeder::Run->new(
        run      => $run,
        runner   => $runner,
        dir      => $data->{dir},
        keep_dir => 0,
        job_ids  => \%jobs,
    );

    $self->{+_FEEDER} = $feeder;
    $self->{+_RUNNER} = $runner;
    $self->{+_PID}    = $data->{pid};
    $self->SUPER::run_command();
}

sub feeder {
    my $self = shift;

    return ($self->{+_FEEDER}, $self->{+_RUNNER}, $self->{+_PID});
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::persist

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
