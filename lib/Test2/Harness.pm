package Test2::Harness;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/sleep/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Runner;
use Test2::Harness::Parser;

use Test2::Util::HashBase qw{
    parser_class
    runner
    listeners
    switches libs env_vars
    jobs slots queue
};

sub STEP_DELAY() { '0.05' }

sub init {
    my $self = shift;

    $self->{+ENV_VARS}  ||= {};
    $self->{+LIBS}      ||= [];
    $self->{+SWITCHES}  ||= [];
    $self->{+LISTENERS} ||= [];

    $self->{+PARSER_CLASS} ||= 'Test2::Harness::Parser';

    $self->{+RUNNER} ||= Test2::Harness::Runner->new();
    $self->{+JOBS}   ||= 1;

    $self->{+SLOTS} = [];
    $self->{+QUEUE} = [];
}

sub environment {
    my $self = shift;

    my $class = blessed($self);

    my %out = (
        'HARNESS_CLASS' => $class,

        'HARNESS_ACTIVE'  => '1',
        'HARNESS_VERSION' => $Test2::Harness::VERSION,

        'T2_HARNESS_ACTIVE'  => '1',
        'T2_HARNESS_VERSION' => $Test2::Harness::VERSION,

        %{$self->{+ENV_VARS}},
    );

    $out{T2_FORMATTER} = 'EventStream';
    $out{HARNESS_JOBS} = $self->{+JOBS} || 1;

    return \%out;
}

sub run {
    my $self = shift;
    my (@files) = @_;

    croak "No files to run" unless @files;

    my $pclass = $self->{+PARSER_CLASS};
    my $listen = $self->{+LISTENERS};
    my $runner = $self->{+RUNNER};
    my $slots  = $self->{+SLOTS};
    my $jobs   = $self->{+JOBS} || 1;
    my $env    = $self->environment;

    my (@queue, @results);

    my $counter = 1;
    my $start_file = sub {
        my $file = shift;

        my $proc = $runner->start(
            $file,

            env      => $self->environment,
            libs     => $self->{+LIBS},
            switches => $self->{+SWITCHES},
        );

        return $pclass->new(
            job       => $counter++,
            proc      => $proc,
            listeners => $listen,
        );
    };

    my $wait = sub {
        my $slot;
        until($slot) {
            for my $s (1 .. $jobs) {
                my $parser = $slots->[$s];

                if ($parser) {
                    $parser->step;
                    next unless $parser->is_done;
                    push @results => $parser->result;
                    $slots->[$s] = undef;
                }

                next if $slots->[$s];

                $slot = $s;
                last;
            }

            last if $slot;
            sleep STEP_DELAY();
        }
        return $slot;
    };

    for my $file (@files) {
        if ($self->{+JOBS} > 1) {
            my $header = $runner->header($file);
            my $concurrent = $header->{features}->{concurrency};
            $concurrent = 1 unless defined($concurrent);

            unless ($concurrent) {
                push @queue => $file;
                next;
            }
        }

        my $slot = $wait->();
        $slots->[$slot] = $start_file->($file); 
    }

    while (@$slots) {
        my $no_sleep = 0;

        my @keep;
        for my $p (@$slots) {
            next unless $p;

            $no_sleep = 1 if $p->step > 0;

            if($p->is_done) {
                push @results => $p->result;
            }
            else {
                push @keep => $p;
            }
        }

        @$slots = @keep;

        sleep STEP_DELAY() unless $no_sleep;
    }

    for my $file (@queue) {
        my $parser = $start_file->($file);

        while(!$parser->is_done) {
            sleep STEP_DELAY() unless $parser->step;
        }

        push @results => $parser->result;
    }

    return \@results;
}

1;
