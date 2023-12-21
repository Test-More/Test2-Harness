package App::Yath::Command::status;
use strict;
use warnings;

our $VERSION = '2.000000';

use Term::Table();

use Test2::Harness::Util qw/render_status_data/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPCAll',
    'App::Yath::Options::Yath',
);

sub group { 'state' }

sub summary { "Status info and process lists for the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will provide health details and a process list for the runner.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    require App::Yath::Client;
    my $client = App::Yath::Client->new(settings => $settings);

    my $data = $client->overall_status;
    my $text = render_status_data($data);
    print "\n$text\n";
}

1;

__END__


sub run {
    my $self = shift;

    my $data = $self->pfile_data();

    my $state = Test2::Harness::Runner::State->new(
        workdir => $self->workdir,
        observe => 1,
    );

    $state->poll;

    print "\n**** Pending tests: ****\n";
    my $pending = $state->pending_tasks;
    for my $run ($state->run, @{$state->pending_runs // []}) {
        next unless $run;
        my $run_id =$run->{run_id} or next;

        print "\nRun $run_id:\n";
        my $pending = $pending->{$run_id} // {};
        my @tasks;
        my @check = ($pending);
        while (my $it = shift @check) {
            my $ref = ref($it);

            if ($ref eq 'ARRAY') {
                push @check => @$it;
                next;
            }

            if ($ref eq 'HASH') {
                if ($it->{job_id}) {
                    push @tasks => $it;
                    next;
                }

                push @check => values %$it;
                next;
            }
        }

        if (!@tasks) {
            print "--No pending tasks for this run--\n";
            next;
        }

        my @rows = map {[$_->{job_id}, $_->{is_try} // $_->{job_try} // 0, $_->{rel_file}, join(', ' => @{$_->{conflicts} // []})]} @tasks;
        my $run_table = Term::Table->new(
            collapse => 1,
            header => [qw/uuid try test conflicts/],
            rows => [ sort { $a->[2] cmp $b->[2] } @rows ],
        );

        print "$_\n" for $run_table->render;
    }

    print "\n**** Runner Stages: ****\n";
    my $stage_status = $state->stage_readiness // {};
    my $reload_status = $state->reload_state // {};
    my $reload_issues = 0;

    my $rows = [];
    for my $stage (keys %$stage_status) {
        my $pid = $stage_status->{$stage} ||= '';
        my $ready = $pid ? 'YES' : 'NO';
        $pid = 'N/A' if $pid && $pid == 1;

        my $issues = keys %{$reload_status->{$stage}};
        my $reload = $issues ? 'YES' : 'NO';
        $reload_issues += $issues;

        push @$rows => [$pid, $stage, $ready, $reload];
    }

    @$rows = sort { $a->[0] <=> $b->[0] } @$rows;

    my $stage_table = Term::Table->new(
        collapse => 1,
        header => [qw/pid stage ready/, 'reload issues'],
        rows => $rows,
    );
    print "$_\n" for $stage_table->render;

    if ($reload_issues) {
        my %seen;
        print "\n**** Reload issues: ****\n";
        for my $stage (sort keys %$reload_status) {
            for my $file (keys %{$reload_status->{$stage}}) {
                next if $seen{$file}++;
                my $data = $reload_status->{$stage}->{$file} or next;
                print "\n==== SOURCE FILE: $file ====\n";
                print $data->{error} if $data->{error};
                print $_ for @{$data->{warnings} // []};
            }
        }
        print "\n";
    }

    print "\n**** Running tests: ****\n";
    my $running = $state->running_tasks;
    my $running_tasks = [values %$running];
    my @rows = map {[$self->get_job_pid($_->{run_id}, $_->{job_id}) // 'N/A', $_->{job_id}, $_->{is_try} // $_->{job_try} // 0, $_->{rel_file}, join(', ' => @{$_->{conflicts} // []})]} @$running_tasks;
    if (@rows) {
        my $run_table = Term::Table->new(
            collapse => 1,
            header => [qw/pid uuid try test conflicts/],
            rows => [ sort { $a->[0] <=> $b->[0] } @rows ],
        );
        print "$_\n" for $run_table->render;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

