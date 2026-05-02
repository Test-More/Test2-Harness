package App::Yath2::Command::speedtag;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Test2::Harness2::Util qw/clean_path/;
use Test2::Harness2::Util::File::JSON;

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
    <max_short
    <max_medium
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

option_group {group => 'speedtag', category => 'Speedtag Options'} => sub {
    option generate_durations_file => (
        type => 'Auto',
        alt  => ['durations', 'duration'],

        description => "Write out a duration json file, if no path is provided 'duration.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/durations.json'],

        autofill => sub { clean_path('durations.json') },

        normalize => sub {
            my $val = shift;
            $val .= '.json' unless $val =~ m/\.json$/;
            return clean_path($val);
        },
    );

    option pretty => (
        type        => 'Bool',
        description => "Generate a pretty 'durations.json' file when combined with --generate-durations-file. (sorted and multilines)",
        default     => 0,
    );
};

sub args_include_tests { 0 }

sub group { 'log parsing' }

sub summary { "Tag tests with duration (short medium long) using a recorded log archive" }

sub cli_args { "[--] LOG max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
Reads per-job durations from a recorded yath log and rewrites the
HARNESS-DURATION-* header on every test file according to the supplied
thresholds. LOG is either a .yath archive file or a directory that looks like
\$workdir/logs.

Per-job durations are derived from harness_job_start / harness_job_end stamps
emitted by App::Yath2::Streamer::Static.
    EOT
}

sub init {
    my $self = shift;

    $self->{+MAX_SHORT}  //= 15;
    $self->{+MAX_MEDIUM} //= 30;
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $initial_dir = clean_path(getcwd());

    my $log = shift @$args;
    unless (defined $log && length $log) {
        $log = App::Yath2::LogArchive->find_latest($settings);
        print STDERR "yath speedtag: using latest archive: $log\n"
            if defined $log && length $log;
    }
    die "You must specify a log archive or directory\n"
        unless defined $log && length $log;
    die "Log source '$log' does not exist\n" unless -e $log;
    $self->{+LOG} = $log;

    $self->{+MAX_SHORT}  = shift @$args if @$args;
    $self->{+MAX_MEDIUM} = shift @$args if @$args;

    die "max short duration must be an integer, got '$self->{+MAX_SHORT}'\n"
        unless $self->{+MAX_SHORT} && $self->{+MAX_SHORT} =~ m/^\d+$/;
    die "max medium duration must be an integer, got '$self->{+MAX_MEDIUM}'\n"
        unless $self->{+MAX_MEDIUM} && $self->{+MAX_MEDIUM} =~ m/^\d+$/;

    require App::Yath2::LogArchive;
    my @runs = App::Yath2::LogArchive->open(path => $log)->runs;
    die "No runs found in '$log'\n" unless @runs;

    my $streamer = App::Yath2::Streamer::Static->new(
        log    => $log,
        runs   => [@runs],
        global => 1,
    );

    my $durations_file = $settings->speedtag->generate_durations_file;
    my %durations;

    # Per-job state we accumulate as the lifecycle stream replays.
    # Each completed job carries a started_at + completed_at stamp; we
    # tag and emit the moment we have both.
    my %job_state;
    my %tagged;
    $streamer->stream(
        callback => sub {
            my ($event) = @_;
            my $f = $event->facet_data // {};

            if (my $start = $f->{harness_job_start}) {
                my $jid = $start->{job_id} // $event->{job_id} // return;
                $job_state{$jid}{start} //= $start->{stamp}    // $event->stamp;
                $job_state{$jid}{file}  //= $start->{abs_file} // $start->{file};
                return;
            }

            return unless my $end = $f->{harness_job_end};

            my $jid  = $end->{job_id}   // $event->{job_id} // return;
            my $file = $end->{abs_file} // $end->{file}     // $job_state{$jid}{file};
            return unless $file;

            $file = clean_path($file);
            return if $tagged{$file}++;

            my $start = $job_state{$jid}{start};
            my $stop  = $end->{stamp} // $event->stamp;
            return unless defined $start && defined $stop;

            my $time = $stop - $start;
            return unless $time > 0;

            my $dur =
                  $time < $self->{+MAX_SHORT}  ? 'short'
                : $time < $self->{+MAX_MEDIUM} ? 'medium'
                :                                'long';

            my $rfh;
            unless (open($rfh, '<', $file)) {
                warn "Could not open file $file for reading\n";
                return;
            }

            my @lines;
            my $injected;
            my ($old, $new);
            for my $line (<$rfh>) {
                if ($line =~ m/^(\s*)#(\s*)HARNESS-(CAT(EGORY)?|DUR(ATION))-(LONG|MEDIUM|SHORT)$/i) {
                    next if $injected++;
                    $old  = $line;
                    $line = "${1}#${2}HARNESS-DURATION-" . uc($dur) . "\n";
                    $new  = $line;
                }
                push @lines => $line;
            }
            close($rfh);

            unless ($injected) {
                my $new_line = "# HARNESS-DURATION-" . uc($dur) . "\n";
                my @header;
                while (@lines && $lines[0] =~ m/^(#|use\s|package\s)/) {
                    push @header => shift @lines;
                }
                unshift @lines => (@header, $new_line);

                $old = "<NO TAG FOUND>";
                $new = $new_line;
            }

            if ($durations_file) {
                my $tfile = $file;
                $tfile =~ s{^\Q$initial_dir\E/+}{};
                $durations{$tfile} = uc($dur);
            }

            if ($settings->harness->dummy) {
                print "Would tag (dummy) file $file with duration '$dur'\n";
                chomp($old);
                chomp($new);
                print "Old Header: $old\nNew Header: $new\n\n";
                return;
            }

            my $wfh;
            unless (open($wfh, '>', $file)) {
                warn "Could not open file $file for writing\n";
                return;
            }

            print $wfh @lines;
            close($wfh);

            print "Tagged '$dur': $file\n";
        },
    );

    if ($durations_file) {
        my $jfile = Test2::Harness2::Util::File::JSON->new(
            name   => $durations_file,
            pretty => $settings->speedtag->pretty,
        );
        $jfile->write(\%durations);
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

