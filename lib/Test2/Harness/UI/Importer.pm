package Test2::Harness::UI::Importer;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Import;

use Test2::Harness::UI::Util::HashBase qw/-config/;

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};
}

sub run {
    my $self = shift;

    my $schema = $self->{+CONFIG}->schema;

    while (1) {
        while (my $run = $schema->resultset('Run')->search({status => 'pending'})->first()) {
            $run->update({status => 'running'});
            $self->process($run);
        }

        sleep 1;
    }
}

sub process {
    my $self = shift;
    my ($run) = @_;

    my $start = time;
    syswrite(\*STDOUT, "Starting run " . $run->run_id . " (" . $run->log_file . ")\n");

    my $status;
    my $ok = eval {
        $run->update({status => 'running'});
        my $import = Test2::Harness::UI::Import->new(
            config => $self->{+CONFIG},
            run    => $run,
        );

        $status = $import->process;

        1;
    };
    my $err = $@;

    unlink($run->log_file);

    my $total = time - $start;

    if ($ok && !$status->{errors}) {
        syswrite(\*STDOUT, "Completed run " . $run->run_id . " (" . $run->log_file . ") in $total seconds.\n");
        $run->update({status => 'complete', passed => $status->{passed}, failed => $status->{failed}});
    }
    else {
        my $error = $ok ? join("\n" => @{$status->{errors}}) : $err;
        syswrite(\*STDOUT, "Failed feed " . $run->run_id . " (" . $run->log_file . ") in $total seconds.\n$error\n");
        $run->update({status => 'failed', error => $error});
    }

    return;
}

1;
