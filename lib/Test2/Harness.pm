package Test2::Harness;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Job;
use Test2::Harness::Runner;
use Test2::Harness::Parser;

use Test2::Util::HashBase qw{
    parser_class
    runner
    listeners
    switches libs env_vars
    jobs
    verbose
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
}

sub environment {
    my $self = shift;

    my $class = blessed($self);

    my %out = (
        'HARNESS_CLASS' => $class,

        'HARNESS_ACTIVE'  => '1',
        'HARNESS_VERSION' => $Test2::Harness::VERSION,

        'HARNESS_IS_VERBOSE' => $self->verbose ? 1 : 0,

        'T2_HARNESS_ACTIVE'  => '1',
        'T2_HARNESS_VERSION' => $Test2::Harness::VERSION,

        'T2_FORMATTER' => 'T2Harness',

        %{$self->{+ENV_VARS}},

        'HARNESS_JOBS' => $self->{+JOBS} || 1,
    );

    return \%out;
}

sub run {
    my $self = shift;
    my (@files) = @_;

    croak "No files to run" unless @files;

    my $pclass = $self->{+PARSER_CLASS};
    my $listen = $self->{+LISTENERS};
    my $runner = $self->{+RUNNER};
    my $jobs   = $self->{+JOBS} || 1;
    my $env    = $self->environment;

    my $slots  = [];
    my (@queue, @results);

    my $counter = 1;
    my $start_file = sub {
        my $file = shift;
        my $job_id = $counter++;

        my $job = Test2::Harness::Job->new(
            id        => $job_id,
            file      => $file,
            listeners => $listen,
        );

        $job->start(
            runner => $runner,
            start_args => {
                env       => $self->environment,
                libs      => $self->{+LIBS},
                switches  => $self->{+SWITCHES},
            },
            parser_class => $pclass,
        );

        return $job;
    };

    my $wait = sub {
        my $slot;
        until($slot) {
            my $no_sleep = 0;
            for my $s (1 .. $jobs) {
                my $job = $slots->[$s];

                if ($job) {
                    $no_sleep = 1 if $job->step;
                    next unless $job->is_done;
                    push @results => $job->result;
                    $slots->[$s] = undef;
                }

                next if $slots->[$s];

                $slot = $s;
                last;
            }

            last if $slot;
            next if $no_sleep;
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
        for my $j (@$slots) {
            next unless $j;

            $no_sleep = 1 if $j->step;

            if($j->is_done) {
                push @results => $j->result;
            }
            else {
                push @keep => $j;
            }
        }

        @$slots = @keep;

        sleep STEP_DELAY() unless $no_sleep;
    }

    for my $file (@queue) {
        my $job = $start_file->($file);

        while(!$job->is_done) {
            sleep STEP_DELAY() unless $job->step;
        }

        push @results => $job->result;
    }

    return \@results;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness - Test2 based test harness.

=head1 DESCRIPTION

This is an alternative to L<Test::Harness>. See the L<App::Yath> module for
more details.

Try running the C<yath> command inside a perl repository.

    $ yath

For help:

    $ yath --help

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
