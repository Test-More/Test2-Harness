package App::Yath::Command::speedtag;
use strict;
use warnings;

our $VERSION = '1.000008';

use Test2::Harness::Util::File::JSONL;

use App::Yath::Options;

use Cwd qw/getcwd/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/-log_file -max_short -max_medium/;
use Test2::Harness::Util qw/clean_path/;

include_options(
    'App::Yath::Options::Debug',
);

option_group {prefix => 'speedtag', category => 'speedtag options'} => sub {
    option generate_durations_file => (
        type => 'd',
        alt         => ['durations', 'duration'],
        description => "Write out a duration json file, if no path is provided 'duration.json' will be used. The .json extension is added automatically if omitted.",

        long_examples  => ['', '=/path/to/durations.json'],

        normalize => \&normalize_duration,
        action    => \&duration_action,
    );

    option pretty => (
        description => "Generate a pretty 'durations.json' file when combined with --generate-durations-file. (sorted and multilines)",
        default     => 0,
    );
};

sub group { 'log' }

sub summary { "Tag tests with duration (short medium long) using a source log" }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
This command will read the test durations from a log and tag/retag all tests
from the log based on the max durations for each type.
    EOT
}

sub init {
    my $self = shift;

    $self->{+MAX_SHORT}  //= 15;
    $self->{+MAX_MEDIUM} //= 30;
}

sub normalize_duration {
    my $val = shift;

    return $val if $val eq '1';

    $val =~ s/\.json$//g;
    $val .= '.json';

    return clean_path($val);
}

sub duration_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    return $$slot = clean_path($norm)
        unless $norm eq '1';

    return if $$slot;
    return $$slot = clean_path('durations.json');
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $initial_dir = clean_path(getcwd());

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    $self->{+MAX_SHORT}  = shift @$args if @$args;
    $self->{+MAX_MEDIUM} = shift @$args if @$args;

    die "max short duration must be an integer, got '$self->{+MAX_SHORT}'"  unless $self->{+MAX_SHORT}  && $self->{+MAX_SHORT} =~ m/^\d+$/;
    die "max short duration must be an integer, got '$self->{+MAX_MEDIUM}'" unless $self->{+MAX_MEDIUM} && $self->{+MAX_MEDIUM} =~ m/^\d+$/;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    my $durations_file = $self->settings->speedtag->generate_durations_file;
    my %durations;

    while(1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            next unless $f->{harness_job_end};

            my $job = {};
            $job->{file} = clean_path( $f->{harness_job_end}->{file} ) if $f->{harness_job_end} && $f->{harness_job_end}->{file};
            $job->{time} = $f->{harness_job_end}->{times}->{totals}->{total} if $f->{harness_job_end} && $f->{harness_job_end}->{times};

            next unless $job->{file} && $job->{time};

            my $dur;
            if ($job->{time} < $self->{+MAX_SHORT}) {
                $dur = 'short';
            }
            elsif ($job->{time} < $self->{+MAX_MEDIUM}) {
                $dur = 'medium';
            }
            else {
                $dur = 'long';
            }

            my $fh;
            unless (open($fh, '<', $job->{file})) {
                warn "Could not open file $job->{file} for reading\n";
                next;
            }

            my @lines;
            my $injected;
            for my $line (<$fh>) {
                if ($line =~ m/^(\s*)#(\s*)HARNESS-(CAT(EGORY)?|DUR(ATION))-(LONG|MEDIUM|SHORT)$/i) {
                    next if $injected++;
                    $line = "${1}#${2}HARNESS-DURATION-" . uc($dur) . "\n";
                }
                push @lines => $line;
            }
            unless ($injected) {
                my $new_line = "# HARNESS-DURATION-" . uc($dur) . "\n";
                my @header;
                while (@lines && $lines[0] =~ m/^(#|use\s|package\s)/) {
                    push @header => shift @lines;
                }

                unshift @lines => (@header, $new_line);
            }

            close($fh);
            unless (open($fh, '>', $job->{file})) {
                warn "Could not open file $job->{file} for writing\n";
                next;
            }

            print $fh @lines;
            close($fh);

            if ( $durations_file ) {
                my $tfile = $job->{file};
                $tfile =~ s{^\Q$initial_dir\E/+}{};
                $durations{ $tfile } = uc( $dur );
            }

            print "Tagged '$dur': $job->{file}\n";
        }
    }

    if ( $durations_file ) {
        my $jfile = Test2::Harness::Util::File::JSON->new(name => $durations_file, pretty => $self->settings->speedtag->pretty );
        $jfile->write( \%durations );
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

