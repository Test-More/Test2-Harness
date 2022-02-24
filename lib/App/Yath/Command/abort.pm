package App::Yath::Command::abort;
use strict;
use warnings;

our $VERSION = '1.000111';

use Time::HiRes qw/sleep/;
use Term::Table;

use File::Spec();

use App::Yath::Util qw/find_pfile/;

use Test2::Harness::Runner::State;
use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use Test2::Harness::Util qw/open_file/;

use parent 'App::Yath::Command::status';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Abort all currently running or queued tests without killing the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will kill all running tests and clear the queue, but will not close the runner.
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
    print "\nTruncating Queue...\n\n";
    $state->truncate;
    $state->poll;

    my $running = $state->running_tasks;
    for my $task (values %$running) {
        my $pid = $self->get_job_pid($task->{run_id}, $task->{job_id}) // next;;
        my $file = $task->{rel_file};
        print "Killing test $pid - $file...\n";
        kill('INT', $pid);
    }

    print "\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

