package Test2::Harness;
use strict;
use warnings;

our $VERSION = '0.000014';

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
    timeout
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

    my $pclass  = $self->{+PARSER_CLASS};
    my $listen  = $self->{+LISTENERS};
    my $runner  = $self->{+RUNNER};
    my $jobs    = $self->{+JOBS} || 1;
    my $timeout = $self->{+TIMEOUT};
    my $env     = $self->environment;

    my $slots  = [];
    my (@queue, @results);

    my $counter = 1;
    my $start_file = sub {
        my $file = shift;
        my $job_id = $counter++;

        my $job = Test2::Harness::Job->new(
            id            => $job_id,
            file          => $file,
            listeners     => $listen,
            event_timeout => $timeout,
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

=head1 USING THE HARNESS IN YOUR DISTRIBUTION

If you want to have your tests run via Test2::Harness instead of
L<Test::Harness> you need to do two things:

=over 4

=item Move your test files

You need to put any tests that you want to run under Test2::Harness into a
directory other than C<t/>. A good name to pick is C<t2/>, as it will not be
picked up by L<Test::Harness> automatically.

=item Add a test.pl script

You need a script that loads Test2::Harness and tells it to run the tests. You
can find this script in C<examples/test.pl> in this distribution. The example
test.pl is listed here for convenience:

    #!/usr/bin/env perl
    use strict;
    use warnings;

    # Change this to list the directories where tests can be found. This should not
    # include the directory where this file lives.

    my @DIRS = ('./t2');

    # PRELOADS GO HERE
    # Example:
    # use Moose;

    ###########################################
    # Do not change anything below this point #
    ###########################################

    use App::Yath;

    # After fork, Yath will break out of this block so that the test file being run
    # in the new process has as small a stack as possible. It would be awful to
    # have a bunch of Test2::Harness frames on all stack traces.
    T2_DO_FILE: {
        # Add eveything in @INC via -I so that using `perl -Idir this_file` will
        # pass the include dirs on to any tests that decline to accept the preload.
        my $yath = App::Yath->new(args => [(map { "-I$_" } @INC), '--exclude=use_harness', @DIRS, @ARGV]);

        # This is where we turn control over to yath.
        my $exit = $yath->run();
        exit($exit);
    }

    # At this point we are in a child process and need to run a test file specified
    # in this package var.
    my $file = $Test2::Harness::Runner::DO_FILE
        or die "No file to run!";

    # Test files do not always return a true value, so we cannot use require. We
    # also cannot trust $!
    $@ = '';
    do $file;
    die $@ if $@;
    exit 0;

Most (if not all) module installation tools will find C<test.pl> and run it,
using the exit value to determine pass/fail.

B<Note:> Since Test2::Harness does not output the traditional TAP, you cannot
use this example as a .t file in t/.

=back

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
