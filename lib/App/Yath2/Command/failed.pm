package App::Yath2::Command::failed;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Test2::Util::Table qw/table/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use App::Yath2::LogArchive();
use App::Yath2::Streamer::Static();

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
    <log
};

use Getopt::Yath;
option_group {group => 'failed', category => 'Command Options'} => sub {
    option brief => (
        type        => 'Bool',
        default     => 0,
        description => 'Show only the files that failed, newline separated, no other output. If a file failed once but passed on a retry it will NOT be shown.',
    );
};

sub args_include_tests { 0 }

sub summary { "Show the failed tests from a log archive" }

sub group { 'log parsing' }

sub cli_args { "[--] LOG [RUN_ID ...]" }

sub description {
    return <<"    EOT";
Lists the test scripts that failed in a recorded yath log. LOG is either a
.yath archive file or a directory that looks like \$workdir/logs (i.e. carries
runs/<id>/ subdirectories for the runs it stores). RUN_IDs, if any, restrict
the analysis to the listed runs; with none, every run stored in the archive
is walked.

The event source is App::Yath2::Streamer::Static, so this command sees the
same lifecycle stream as 'yath replay'. Per-job assertions used for the
"Subtests" column are read directly from each failed job's JSONL artifact.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $log = shift @$args;
    unless (defined $log && length $log) {
        $log = App::Yath2::LogArchive->find_latest($settings);
        print STDERR "yath failed: using latest archive: $log\n"
            if defined $log && length $log;
    }

    die "You must specify a log archive or directory\n"
        unless defined $log && length $log;

    die "Log source '$log' does not exist\n" unless -e $log;

    $self->{+LOG} = $log;

    my $archive  = App::Yath2::LogArchive->open(path => $log);
    my @all_runs = $archive->runs;
    die "No runs found in '$log'\n" unless @all_runs;

    my @requested = @$args;
    if (@requested) {
        my %known = map { $_ => 1 } @all_runs;
        for my $rid (@requested) {
            die "unknown run '$rid' in '$log'\n" unless $known{$rid};
        }
    }
    else {
        @requested = @all_runs;
    }

    my $streamer = App::Yath2::Streamer::Static->new(
        log    => $log,
        runs   => [@requested],
        global => 1,
    );

    # Per-file aggregate. Each file collects every harness_job_end we
    # see for it (one per try, keyed by the synthesised job_id).
    my %by_file;
    $streamer->stream(
        callback => sub {
            my ($event) = @_;
            my $f       = $event->facet_data // {};
            my $end     = $f->{harness_job_end} or return;

            my $rel = $end->{rel_file} // $end->{file} // $end->{abs_file};
            return unless defined $rel;

            push @{$by_file{$rel}{ends}} => {
                run_id  => $event->{run_id},
                job_id  => $end->{job_id}    // $event->{job_id},
                job_try => $event->{job_try} // 0,
                fail    => $end->{fail} ? 1 : 0,
                stamp   => $end->{stamp} // $event->stamp,
            };
        },
    );

    my $brief = $settings->failed->brief;
    my @rows;
    for my $rel (sort keys %by_file) {
        my @ends = sort { ($a->{stamp} // 0) <=> ($b->{stamp} // 0) } @{$by_file{$rel}{ends}};

        my $any_fail = grep { $_->{fail} } @ends;
        next unless $any_fail;

        my $final     = $ends[-1];
        my $succeeded = $final->{fail} ? 0 : 1;

        if ($brief) {
            print $rel, "\n" unless $succeeded;
            next;
        }

        my $subtests = $self->_collect_subtests($archive, \@ends);

        push @rows => [
            $rel,
            scalar(@ends),
            $subtests,
            $succeeded ? 'YES' : 'NO',
        ];
    }

    return 0 if $brief;

    unless (@rows) {
        print "\nNo jobs failed!\n";
        return 0;
    }

    print "\nThe following jobs failed at least once:\n";
    print join "\n" => table(
        collapse => 1,
        header   => ['Test File', 'Times Run', 'Subtests', 'Succeeded Eventually?'],
        rows     => \@rows,
    );
    print "\n";

    return 0;
}

# Walk each failed try's per-job JSONL to extract the subtest names.
# The streamer does not currently stamp provenance onto general events
# (per ARCHITECTURE.md §12.5 provenance comes from the log path), so we
# read each per-job log directly via the archive instead.
sub _collect_subtests {
    my $self = shift;
    my ($archive, $ends) = @_;

    my %seen;
    my @names;
    for my $end (@$ends) {
        next unless $end->{fail};
        my $jid = $end->{job_id}  // next;
        my $rid = $end->{run_id}  // next;
        my $try = $end->{job_try} // 0;

        # Phase 4.5 per-try layout: runs/<run>/tests/<job>/<try>.jsonl.
        # Older callers may pass tries with no extension awareness;
        # has_file() answers in either compressed or plain form.
        my $rel = "runs/$rid/tests/$jid/$try.jsonl";
        next unless $archive->has_file($rel);

        my $fh = $archive->read_file($rel);
        while (my $line = <$fh>) {
            chomp $line;
            next unless length $line;
            my $event = eval { decode_json($line) } or next;
            my $f     = $event->{facet_data}        or next;

            next unless $f->{parent};
            next if $f->{trace} && $f->{trace}{nested};
            next unless $self->_include_subtest($f);

            for my $name ($self->_subtests($f)) {
                next if $seen{$name}++;
                push @names => $name;
            }
        }
        close $fh;
    }

    return join "\n" => sort @names;
}

sub _include_subtest {
    my $self = shift;
    my ($f) = @_;

    return 0 unless $f->{parent} && keys %{$f->{parent}};
    return 0 if $f->{assert} && $f->{assert}{pass};
    return 0 if !$f->{assert} || !keys %{$f->{assert}};
    return 0 if $f->{amnesty} && @{$f->{amnesty}};
    return 1;
}

sub _subtests {
    my $self = shift;
    my ($f, $prefix) = @_;

    return unless $self->_include_subtest($f);

    my $name = $f->{assert}{details};
    unless ($name) {
        my $frame = $f->{trace}{frame};
        $name = "Unnamed Subtest";
        $name .= " ($frame->[1] line $frame->[2])"
            if $frame && $frame->[1] && $frame->[2];
    }

    $name = "$prefix -> $name" if $prefix;

    my @out = ($name);
    for my $child (@{$f->{parent}{children}}) {
        next unless $child->{parent};
        push @out => $self->_subtests($child, $name);
    }

    return @out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

