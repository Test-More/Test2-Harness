package App::Yath::Command::collector;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep time/;
use Test2::Harness::Util qw/fqmod clean_path mod2file/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use Test2::Harness::State;
use Test2::Harness::Collector;

use App::Yath::Options;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +state
    +writer
};

include_options(
    'App::Yath::Options::Debug',
);

sub internal_only   { 1 }
sub summary         { "For internal use only" }
sub name            { 'collector' }

option_group {prefix => 'collector', category => 'collector options'} => sub {
    option parser => (
        type           => 's',
        default        => 'Test2::Harness::Collector::IOParser',
        description    => "The parser to use when reading from stderr and stdout.",
        long_examples  => [' IOParser', ' StreamParser'],
        short_examples => [' IOParser', ' StreamParser'],
        normalize      => sub { fqmod('Test2::Harness::Collector::IOParser', $_[0]) },
    );

    option auditor => (
        type           => 'd',
        description    => "Enable or specify an auditor",
        long_examples  => ['', '=Auditor'],
        short_examples => ['', '=Auditor'],
        normalize      => sub { fqmod('Test2::Harness::Collector::Auditor', $_[0]) },
        autofill       => '+Test2::Harness::Collector::Auditor',
    );

    option aggregator => (
        type           => 's',
        description    => "What aggregator should receive the events (also requires a state file)",
        long_examples  => [' runner', ' renderer'],
        short_examples => [' runner', ' renderer'],
    );

    option aggregator_timeout => (
        type           => 's',
        description    => 'Timeout when waiting for the aggregator to show up in the state file',
        default        => 10,
        long_examples  => [' 10'],
        short_examples => [' 10'],
    );

    option state_file => (
        type           => 's',
        description    => "State file for the yath instance",
        long_examples  => [' /path/to/statefile'],
        short_examples => [' /path/to/statefile'],
        normalize      => \&clean_path,
    );

    option output_file => (
        type           => 's',
        description    => "Output file to use instead of an aggregator or stdout",
        long_examples  => [' /path/to/output.jsonl'],
        short_examples => [' /path/to/output.jsonl'],
        normalize      => \&clean_path,
    );

    option summary_file => (
        type           => 's',
        description    => "Summary file that will contain an up-to-date summary status as the test runs, and a final state when test is complete",
        long_examples  => [' /path/to/summary.json'],
        short_examples => [' /path/to/summary.json'],
        normalize      => \&clean_path,
    );

    option merge_io => (
        type        => 'b',
        description => "Merge STDOUT and STDERR into a single stream",
        default     => 0,
    );

    option run_id => (
        type        => 's',
        default     => 0,
        description => 'Run ID to use for parsed events',
    );

    option job_id => (
        type        => 's',
        default     => 0,
        description => 'Job ID to use for parsed events',
    );

    option job_try => (
        type        => 's',
        default     => 0,
        description => 'Job Try',
    );

    option parent_pid => (
        type        => 's',
        default     => sub { getppid() },
        description => 'Pid of parent process',
    );

    option type => (
        type        => 's',
        description => "Type of process being collected",
        default     => 'unknown',
    );

    option name => (
        type        => 's',
        description => "Name of process being collected",
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'h',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables to set when each test is run.',
    );
};

sub state {
    my $self = shift;

    return $self->{+STATE} if $self->{+STATE};

    my $settings = $self->settings;

    my $state_file = $settings->collector->state_file or die "'state_file' is a required argument.\n";
    if (-e $state_file) {
        return $self->{+STATE} = Test2::Harness::State->new(state_file => $state_file);
    }
    else {
        return $self->{+STATE} = Test2::Harness::State->new(state_file => $state_file, settings => $settings);
    }
}

sub writer {
    my $self = shift;

    return $self->{+WRITER} if $self->{+WRITER};

    my $settings = $self->settings;

    if (my $agg = $settings->collector->aggregator) {
        my $state = $self->state;

        my $timeout = $settings->collector->aggregator_timeout;
        my $start = time;
        my $agg_data;

        while (!$agg_data) {
            $state->transaction(r => sub {
                my ($state, $data) = @_;
                $agg_data = $data->aggregators->{$agg};
            });

            die "Timed out waiting for aggregator ($agg) after $timeout seconds.\n" if (time - $start) > $timeout;
            sleep 0.2 unless $agg_data;
        }

        require Atomic::Pipe;
        my $w = Atomic::Pipe->write_fifo($agg_data->{fifo});

        return $self->{+WRITER} = sub { $w->write_message(encode_json($_[0])) };
    }

    if (my $out_file = $settings->collector->output_file) {
        die "Output file '$out_file' already exists!\n" if -e $out_file;
        require Test2::Harness::Util::File::JSONL;
        my $of = Test2::Harness::Util::File::JSONL->new(name => $out_file);
        return $self->{+WRITER} = sub { $of->write($_[0]) };
    }

    return $self->{+WRITER} = sub { print STDOUT encode_json($_[0]), "\n" };
}

sub run {
    my $self = shift;
    my @exec = @{$self->args // []};
    shift @exec while @exec && $exec[0] eq '--';

    my $settings = $self->settings;

    my $writer = $self->writer;

    # Init the stream parser
    my $parser_class = $settings->collector->parser;
    require(mod2file($parser_class));
    my $parser = $parser_class->new(
        run_id  => $settings->collector->run_id,
        job_id  => $settings->collector->job_id,
        job_try => $settings->collector->job_try,
        name    => $settings->collector->name // join(' ' => @exec),
        type    => $settings->collector->type,
    );

    my $name = $settings->collector->name // join(' ' => @exec);

    my $event_cb;
    if (my $auditor_class = $settings->collector->auditor) {
        require(mod2file($auditor_class));
        my $auditor = $auditor_class->new(
            file         => $name,
            run_id       => $settings->collector->run_id,
            job_id       => $settings->collector->job_id,
            job_try      => $settings->collector->job_try,
            summary_file => $settings->collector->summary_file,
            state        => $self->state,
        );

        $event_cb = sub {
            my @events = ($_[1]);
            @events = map { $parser->parse_io($_) } @events;
            @events = map { $auditor->audit($_) } @events;
            $writer->($_) for @events;
        };
    }
    else {
        $event_cb = sub { $writer->($_) for $parser->parse_io($_[1]) };
    }

    my $collector = Test2::Harness::Collector->new(
        state         => $self->state,
        merge_outputs => $self->settings->collector->merge_io,
        event_cb      => $event_cb,
        run_id        => $settings->collector->run_id,
        job_id        => $settings->collector->job_id,
        job_try       => $settings->collector->job_try,
    );

    # Start the child
    $collector->run(
        name       => $name,
        type       => $settings->collector->type,
        env        => $settings->collector->env_vars,
        parent_pid => $settings->collector->parent_pid,
        launch_cb  => sub { exec(@exec) },
    );

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

