package Test2::Harness::UI::Importer;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Import;

use Test2::Harness::UI::Util::HashBase qw/-schema -max/;
use Parallel::Runner;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};

    $self->{+MAX} ||= 1;
}

sub run {
    my $self = shift;

    my $schema = $self->{+SCHEMA};

    my $runner = Parallel::Runner->new($self->{+MAX});

    while(1) {
        while (my $feed = $schema->resultset('Feed')->search({status => 'pending'})->first()) {
            $feed->update({status => 'running'});
            $runner->run(sub { $self->process($feed) });
        }

        sleep 1;
    }
}

sub process {
    my $self = shift;
    my ($feed) = @_;

    syswrite(\*STDOUT, "Starting feed " . $feed->feed_id . " (" . $feed->name . ")\n");

    my $status;
    my $ok = eval {
        my $import = Test2::Harness::UI::Import->new(
            schema => $self->{+SCHEMA},
            feed => $feed,
        );

        $status = $import->run;

        1;
    };
    my $err = $@;

    unlink($feed->local_file);

    if ($ok && !$status->{errors}) {
        $feed->update({status => 'complete'});
        syswrite(\*STDOUT, "Completed feed " . $feed->feed_id . " (" . $feed->name . ")\n");
    }
    else {
        my $error = $ok ? join("\n" => @{$status->{errors}}) : $err;
        $feed->update({status => 'failed', error => $err});
        syswrite(\*STDOUT, "Failed feed " . $feed->feed_id . " (" . $feed->name . ")\n");
    }

    return;
}

1;
