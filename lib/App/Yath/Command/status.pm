package App::Yath::Command::status;
use strict;
use warnings;

our $VERSION = '1.000090';

use Term::Table();
use File::Spec();

use App::Yath::Util qw/find_pfile/;

use Test2::Harness::Runner::State;
use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Status info and process lists for the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will provide health details and a process list for the runner.
    EOT
}

sub run {
    my $self = shift;

    my $pfile = find_pfile($self->settings)
        or die "No persistent harness was found for the current path.\n";

    print "\nFound: $pfile\n";
    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";

    my $state = Test2::Harness::Runner::State->new(
        job_count    => 1,
        workdir      => $self->workdir,
    );

    $state->poll;

    print "\n**** Pending tests: ****\n";
    my $pending = $state->pending_tasks;
    for my $run ($state->run, @{$state->pending_runs}) {
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
    my $stage_table = Term::Table->new(
        collapse => 1,
        header => [qw/pid stage ready/],
        rows => [ sort { $a->[0] <=> $b->[0] } map {my $pid = $stage_status->{$_}; my $ready = $pid ? 'YES' : 'NO'; $pid ||= ''; $pid = 'N/A' if $pid && $pid == 1; [$pid, $_, $ready]} keys %$stage_status ],
    );
    print "$_\n" for $stage_table->render;

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

