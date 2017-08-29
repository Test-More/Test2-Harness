package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '0.001001';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use App::Yath::Util qw/fully_qualify/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    -help

    -log_file
    -jobs

    -verbose
    -formatter
    -renderer
    -show_job_info
    -show_run_info
    -show_job_launch
    -show_job_end
};

use Getopt::Long qw/GetOptionsFromArray/;

sub summary { "replay from a test log" }

sub usage {
    my $self = shift;
    my $name = $self->name;

    return <<"    EOT";
Usage: $0 $name [options] event_log.jsonl[.gz|.bz2] [job1, job2, ...]

This yath command will re-run the harness against an event log produced by a
previous test run. The only required argument is the path to the log file,
which maybe compressed. Any extra arguments are assumed to be job id's. If you
list any jobs, only listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.

  Simple Options:

    -h --help           Exit after showing this help message

  Rendering/Display Options:

    -v --verbose        Turn on verbosity, specify it multiple times to increase
                        verbosity

    -r '+Fully::Qualified::Renderer'
    --renderer 'Renderer::Postfix'

                        Specify an alternative renderer, this is what is
                        responsible for displaying events. If you do not prefix
                        with a '+' then 'Test2::Harness::Renderer::' will be
                        prefixed to your argument.
                        Default: '+Test2::Harness::Renderer::Formatter'

        Options specific to The 'Formatter' renderer:

          --show-job-end        Notify when a job ends (Default: On)
          --no-show-job-end

          --show-job-launch     Notify when a job starts
          --no-show-job-launch  (Default: on in verbose level 1+)

          --show-job-info       Print each jobs settings as JSON
          --no-show-job-info    (Default: Off, on when verbose > 1)

          --show-run-info       Print the run settings as JSON
          --no-show-run-info    (Default: Off, on when verbose > 1)

          --formatter '+Fully::Qualified::Formatter'
          --formatter 'Formatter::Postfix'

                                Specify which Test2 formatter to use
                                (Default: '+Test2::Formatter::Test2')


    EOT
}

sub init {
    my $self = shift;

    if ($self->args && @{$self->args}) {
        my (@args, $file, @jobs);

        my $last_mark = '';
        for my $arg (@{$self->args}) {
            if ($last_mark eq '--') {
                if ($file) {
                    push @jobs => $arg;
                }
                else {
                    $file = $arg;
                }
            }
            else {
                if ($arg eq '--' || $arg eq '::') {
                    $last_mark = $arg;
                    next;
                }
                push @args => $arg;
            }
        }

        Getopt::Long::Configure("bundling");

        my $args_ok = GetOptionsFromArray \@args => (
            'r|renderer'       => \($self->{+RENDERER}),
            'v|verbose+'       => \($self->{+VERBOSE}),
            'h|help'           => \($self->{+HELP}),
            'formatter=s'      => \($self->{+FORMATTER}),
            'show-job-end!'    => \($self->{+SHOW_JOB_END}),
            'show-job-info!'   => \($self->{+SHOW_JOB_INFO}),
            'show-job-launch!' => \($self->{+SHOW_JOB_LAUNCH}),
            'show-run-info!'   => \($self->{+SHOW_RUN_INFO}),
        );
        die "Could not parse the command line options given.\n" unless $args_ok;

        if ($file) {
            push @jobs => @args;
        }
        else {
            ($file, @jobs) = @args;
        }

        die "No file specified.\n" if !$file;

        $self->{+JOBS} = {map { $_ => 1 } @jobs} if @jobs;
        $self->{+LOG_FILE} = $file;
    }

    # Defaults
    $self->{+FORMATTER} ||= '+Test2::Formatter::Test2';
    $self->{+RENDERER} ||= '+Test2::Harness::Renderer::Formatter';

    if ($self->{+VERBOSE}) {
        $self->{+SHOW_JOB_INFO}   = $self->{+VERBOSE} - 1 unless defined $self->{+SHOW_JOB_INFO};
        $self->{+SHOW_RUN_INFO}   = $self->{+VERBOSE} - 1 unless defined $self->{+SHOW_RUN_INFO};
        $self->{+SHOW_JOB_LAUNCH} = 1                     unless defined $self->{+SHOW_JOB_LAUNCH};
        $self->{+SHOW_JOB_END}    = 1                     unless defined $self->{+SHOW_JOB_END};
    }
    else {
        $self->{+VERBOSE} = 0; # Normalize
        $self->{+SHOW_JOB_INFO}   = 0 unless defined $self->{+SHOW_JOB_INFO};
        $self->{+SHOW_RUN_INFO}   = 0 unless defined $self->{+SHOW_RUN_INFO};
        $self->{+SHOW_JOB_LAUNCH} = 0 unless defined $self->{+SHOW_JOB_LAUNCH};
        $self->{+SHOW_JOB_END}    = 1 unless defined $self->{+SHOW_JOB_END};
    }
}

sub run {
    my $self = shift;

    if ($self->{+HELP}) {
        print $self->usage;
        exit 0;
    }

    my $feeder = Test2::Harness::Feeder::JSONL->new(file => $self->{+LOG_FILE});

    my $renderers = [];
    if (my $r = $self->{+RENDERER}) {
        if ($r eq '+Test2::Harness::Renderer::Formatter' || $r eq 'Formatter') {
            require Test2::Harness::Renderer::Formatter;

            my $formatter = $self->{+FORMATTER} or die "No formatter specified.\n";
            my $f_class;

            if ($formatter eq '+Test2::Formatter::Test2' || $formatter eq 'Test2') {
                require Test2::Formatter::Test2;
                $f_class = 'Test2::Formatter::Test2';
            }
            else {
                $f_class = fully_qualify('Test2::Formatter', $formatter);
                my $file = pkg_to_file($f_class);
                require $file;
            }

            push @$renderers => Test2::Harness::Renderer::Formatter->new(
                show_job_info   => $self->{+SHOW_JOB_INFO},
                show_run_info   => $self->{+SHOW_RUN_INFO},
                show_job_launch => $self->{+SHOW_JOB_LAUNCH},
                show_job_end    => $self->{+SHOW_JOB_END},
                formatter       => $f_class->new(verbose => $self->{+VERBOSE}),
            );
        }
        elsif ($self->{+FORMATTER}) {
            die "The formatter option is only available when the 'Formatter' renderer is in use.\n";
        }
        else {
            my $r_class = fully_qualify('Test2::Harness::Renderer', $r);
            require $r_class;
            push @$renderers => $r_class->new(verbose => $self->{+VERBOSE});
        }
    }

    my $harness = Test2::Harness->new(
        live      => 0,
        feeder    => $feeder,
        renderers => $renderers,
        jobs      => $self->{+JOBS},
        run_id    => 'replay',
    );

    my $stat = $harness->run();

    my $exit = 0;
    my $bad = $stat->{fail};
    if (@$bad) {
        print "\nThe following test files failed:\n";
        print "  ", $_, "\n" for @$bad;
        print "\n";
        $exit += @$bad;
    }
    else {
        print "\nAll tests were successful!\n\n";
    }

    $exit = 255 if $exit > 255;

    return $exit;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::replay - Command to replay a test run from an event log.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
