package App::Yath::Command::failed;
use strict;
use warnings;

our $VERSION = '1.000162';

use Test2::Util::Table qw/table/;
use Test2::Harness::Util::File::JSONL;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{<log_file};

use App::Yath::Options;

option brief => (
    prefix => 'display',
    category => 'Display Options',
    description => 'Show only the files that failed, newline separated, no other output. If a file failed once but passed on a retry it will NOT be shown.',
);

sub summary { "Show the failed tests from an event log" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will list the test scripts from an event log that have failed.
The only required argument is the path to the log file, which may be compressed.
Any extra arguments are assumed to be job id's. If you list any jobs,
only the listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    my %failed;

    while(1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            push @{$failed{$job_id}->{subtests}} => $self->subtests($f)
                if $f->{parent} && !$f->{trace}->{nested} && $self->include_subtest($f);

            next unless $f->{harness_job_end};
            next unless $f->{harness_job_end}->{fail} || $failed{$job_id};

            push @{$failed{$job_id}->{ends}} => $f->{harness_job_end};
        }
    }

    my $rows = [];
    while (my ($job_id, $data) = each %failed) {
        my $ends = $data->{ends} // [];

        my %seen;
        my $subtests = join "\n" => grep { !$seen{$_}++ } sort @{$data->{subtests} // []};

        if ($settings->display->brief) {
            print $ends->[-1]->{rel_file}, "\n" if $ends->[-1]->{fail};
        }
        else {
            push @$rows => [$job_id, scalar(@$ends), $ends->[-1]->{rel_file}, $subtests, $ends->[-1]->{fail} ? "NO" : "YES"];
        }
    }

    return 0 if $settings->display->brief;

    unless (@$rows) {
        print "\nNo jobs failed!\n";
        return 0;
    }

    print "\nThe following jobs failed at least once:\n";
    print join "\n" => table(
        collapse => 1,
        header => ['Job ID', 'Times Run', 'Test File', "Subtests", "Succeeded Eventually?"],
        rows   => $rows,
    );
    print "\n";

    return 0;
}

sub include_subtest {
    my $self = shift;
    my ($f) = @_;

    return 0 unless $f->{parent} && keys %{$f->{parent}};
    return 0 if $f->{assert}->{pass} || !keys %{$f->{assert}};
    return 0 if $f->{amnesty} && @{$f->{amnesty}};
    return 1;
}

sub subtests {
    my $self = shift;
    my ($f, $prefix) = @_;

    return unless $self->include_subtest($f);

    my $name = $f->{assert}->{details};
    unless ($name) {
        my $frame = $f->{trace}->{frame};
        $name = "Unnamed Subtest";
        $name .= " ($frame->[1] line $frame->[2])" if $frame->[1] && $frame->[2];
    }

    $name = "$prefix -> $name" if $prefix;

    my @out;
    push @out => $name;
    for my $child (@{$f->{parent}->{children}}) {
        next unless $child->{parent};
        push @out => $self->subtests($child, $name);
    }

    return @out;
}


1;

__END__

=head1 POD IS AUTO-GENERATED

