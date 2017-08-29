package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001001';

use File::Temp qw/tempdir/;
use IO::Compress::Bzip2 qw/$Bzip2Error/;
use IO::Compress::Gzip qw/$GzipError/;

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run;
use Test2::Harness;

use Test2::Harness::Util qw/read_file open_file/;

use App::Yath::Util qw/fully_qualify/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    -dir

    -show_opts
    -help

    -run_id

    -keep_dir
    -job_count
    -switches
    -libs -lib -blib
    -preload
    -input
    -search
    -unsafe_inc
    -env_vars
    -test_args
    -chdir
    -no_stream
    -no_fork

    -verbose
    -formatter
    -renderer
    -show_job_info
    -show_run_info
    -show_job_launch
    -show_job_end

    -event_timeout
    -post_exit_timeout

    -log
    -log_file
    -bzip2_log
    -gzip_log
};

use Getopt::Long qw/GetOptionsFromArray/;

sub summary { "run tests" }

sub usage {
    my $self = shift;
    my $name = $self->name;

    return <<"    EOT";
Usage: $0 $name [options] [--] [test files/dirs] [::] [arguments to test scripts]

This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' dirctories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.

  Simple Options:

    --id 12345          Specify the run-id (Default: current unix time)
    --run_id 12345      Alias for --id

    --show-opts         Exit after showing what yath thinks your options mean

    -h --help           Exit after showing this help message

    --unsafe-inc        Turn on '.' in \@INC (Default: On, but this may change)

    -k --keep-dir       Keep the temporary work directory for review

    -t /path/to/tmp     Specify an alternative temp directory
    --tmpdir /tmp       (Default: System temp)

    -d path/to/dir      Specify a custom work directory
    --dir path/to/dir   (Default: A new temp directory)

    -j #   --jobs #     Specify the number of jobs to run concurrently
    --job-count $       (Default: 1)

    -c path/to/dir      Tell yath to chdir to a new directory before starting
    --chdir path/to/dir

    --stream            Use Test2::Formatter::Stream when running tests (Default:On)
    --no-stream         Do not use Test2::Formatter::Stream (Legacy Compatability)
    --TAP --tap         Aliases for --no-stream

    --fork              Fork to start tests instead of starting a new perl (Default: On)
    --no-fork           Do not fork to start new tests
                        This is only supported on platforms with a true 'fork'
                        implementation.

    --event_timeout #   How long to wait for events before timing out.
    --et #              This is used to kill tests that appear frozen.
                        (Default: 60 seconds)

    --post_exit_timeout How long to wait for a test to send final events after
    --pet #             exiting with an exit value of 0, but an incomplete
                        plan. (Default: 15 seconds)

  Library Path Options:

    -b --blib           Include 'blib/lib' and 'blib/arch' (Default: On)
    --no-blib           Do not include 'blib/lib' and 'blib/arch'

    -l --lib            Include the 'lib' dir (Default: On)
    --no-lib            Do not include 'lib'

    -I path/to/lib      Include a specific path. This can be specified multiple
                        times

    -p My::Lib          Preload a perl module (This implies --fork)
    --preload My::Lib

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

  Logging Options:

          -L --log      Enable logging of RAW events, before processing
                        The log file can be replayed later using the
                        'yath replay logfile.jsonl' command.
                        The log file will be in JSONL format, each line will be
                        the complete JSON for an event.
                        (Default: Off)

          -B --bz2      Compress the log file using bzip2, this will
          --bzip2-log   automatically append .bz2 to your log file name
                        This implies -L (Default: Off)

          -G --gz       Compress the log file using gzip, this will
          --gzip-log    automatically append .gz to your log file name
                        This implies -L (Default: Off)

          -F path/to/log.jsonl
          --log-file logfile.jsonl

                        Specify a custom log filename. '.jsonl' is not appended
                        for you. If you specify gzip or bzip2 the .bz2 or .gz
                        will be added for you.
                        This implies -L (Default: event-log-[run-id].jsonl)

  Options Passed to Test Jobs:

          -i "STDIN for each test"
          --input "STDIN for each test"

                Specify a string that will be written to each tests STDIN. Tests
                will NOT share a filehandle, they each get the full string to
                STDIN.

          -f path/to/input_file
          --input-file path/to/input_file

                Specify a file that will be written to each tests STDIN. Tests
                will NOT share a filehandle, they each get the full string to
                STDIN.

          -A
          --author-testing

                Set the 'AUTHOR_TESTING' environment variable to true.

          -E "VAR=VALUE"
          --env-vars=s "VAR=VALUE"

                Specify environment variables to set when running each test.
                You may specify this multiple times to set multiple variables.

          -S "SWITCH"
          -S "SWITCH=VALUE"
          --switch "SWITCH"
          --switch "SWITCH=VALUE"

                Specify perl switches for all tests. This option prevents
                preload from working.

    EOT
}

sub init {
    my $self = shift;

    my ($tmp_dir);

    if ($self->args && @{$self->args}) {
        my (@args, @search, @test_args);

        my $last_mark = '';
        for my $arg (@{$self->args}) {
            if ($last_mark eq '::') {
                push @test_args => $arg;
            }
            elsif ($last_mark eq '--') {
                if ($arg eq '::') {
                    $last_mark = $arg;
                    next;
                }
                push @search => $arg;
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
            'F|log-file=s'       => \($self->{+LOG_FILE}),
            'I|include=s@'       => \($self->{+LIBS}),
            'L|log'              => \($self->{+LOG}),
            'B|bz2|bzip2-log'    => \($self->{+BZIP2_LOG}),
            'G|gz|gzip-log'      => \($self->{+GZIP_LOG}),
            'b|blib!'            => \($self->{+BLIB}),
            'd|dir=s'            => \($self->{+DIR}),
            'i|input=s'          => \($self->{+INPUT}),
            'j|jobs|job-count=i' => \($self->{+JOB_COUNT}),
            'k|keep-dir'         => \($self->{+KEEP_DIR}),
            'l|lib!'             => \($self->{+LIB}),
            'p|preload=s@'       => \($self->{+PRELOAD}),
            'r|renderer=s'       => \($self->{+RENDERER}),
            'v|verbose+'         => \($self->{+VERBOSE}),
            'c|chdir=s'          => \($self->{+CHDIR}),
            'id|run-id=s'        => \($self->{+RUN_ID}),
            'show-opts'          => \($self->{+SHOW_OPTS}),
            'h|help'             => \($self->{+HELP}),
            't|tmpdir=s'         => \$tmp_dir,

            'et|event_timeout=i'      => \($self->{+EVENT_TIMEOUT}),
            'pet|post_exit_timeout=i' => \($self->{+POST_EXIT_TIMEOUT}),

            'A|author-testing' => sub { $self->{+ENV_VARS}->{AUTHOR_TESTING} = 1 },

            'T|TAP|tap|no-stream' => \($self->{+NO_STREAM}),
            'stream'              => sub { $self->{+NO_STREAM} = 0 },

            'fork' => sub { $self->{+NO_FORK} = 0 },
            'no-fork' => \($self->{+NO_FORK}),

            'formatter=s'      => \($self->{+FORMATTER}),
            'show-job-end!'    => \($self->{+SHOW_JOB_END}),
            'show-job-info!'   => \($self->{+SHOW_JOB_INFO}),
            'show-job-launch!' => \($self->{+SHOW_JOB_LAUNCH}),
            'show-run-info!'   => \($self->{+SHOW_RUN_INFO}),
            'unsafe-inc!'      => \($self->{+UNSAFE_INC}),

            'f|input-file=s' => sub {
                my ($opt, $arg) = @_;
                die "Input file not found: $arg\n" unless -f $arg;
                warn "Input file is overriding another source of input.\n" if $self->{+INPUT};
                $self->{+INPUT} = read_file($arg);
            },

            'E|env-vars=s' => sub {
                my ($opt, $arg) = @_;
                my ($key, $val) = split /=/, $arg, 2;
                $self->{+ENV_VARS}->{$key} = $val;
            },

            'S|switch=s' => sub {
                my ($opt, $arg) = @_;
                my ($switch, $val) = split /=/, $arg, 2;
                push @{$self->{+SWITCHES}} => $switch;
                push @{$self->{+SWITCHES}} => $val if defined $val;
            },
        );
        die "Could not parse the command line options given.\n" unless $args_ok;

        $self->{+TEST_ARGS} = \@test_args;
        $self->{+SEARCH} = [@search, @args] if @search || @args;
    }


    # Defaults
    $self->{+RUN_ID} ||= time;
    $self->{+SEARCH} ||= [grep { -e $_ } './t', './t2', 'test.pl'];
    $self->{+KEEP_DIR} = 0 unless defined $self->{+KEEP_DIR};
    $self->{+JOB_COUNT} ||= 1;
    $self->{+LIB}  = 1 unless defined $self->{+LIB};
    $self->{+BLIB} = 1 unless defined $self->{+BLIB};
    $self->{+FORMATTER} ||= '+Test2::Formatter::Test2';
    $self->{+RENDERER}  ||= '+Test2::Harness::Renderer::Formatter';

    $self->{+EVENT_TIMEOUT}     = 60 unless defined $self->{+EVENT_TIMEOUT};
    $self->{+POST_EXIT_TIMEOUT} = 15 unless defined $self->{+POST_EXIT_TIMEOUT};

    $self->{+ENV_VARS} ||= {};

    $self->{+LOG} ||= 1 if $self->{+LOG_FILE} || $self->{+BZIP2_LOG} || $self->{+GZIP_LOG};
    $self->{+LOG_FILE} ||= "event-log-$self->{+RUN_ID}.jsonl" if $self->{+LOG};
    die "You cannot select both bzip2 and gzip for the log.\n"
        if $self->{+BZIP2_LOG} && $self->{+GZIP_LOG};

    if ($self->{+VERBOSE}) {
        $self->{+SHOW_JOB_INFO}   = $self->{+VERBOSE} - 1 unless defined $self->{+SHOW_JOB_INFO};
        $self->{+SHOW_RUN_INFO}   = $self->{+VERBOSE} - 1 unless defined $self->{+SHOW_RUN_INFO};
        $self->{+SHOW_JOB_LAUNCH} = 1                     unless defined $self->{+SHOW_JOB_LAUNCH};
        $self->{+SHOW_JOB_END}    = 1                     unless defined $self->{+SHOW_JOB_END};

        $self->{+ENV_VARS}->{HARNESS_IS_VERBOSE} = 1;
        $self->{+ENV_VARS}->{T2_HARNESS_IS_VERBOSE} = 1;
    }
    else {
        $self->{+VERBOSE} = 0; # Normalize
        $self->{+SHOW_JOB_INFO}   = 0 unless defined $self->{+SHOW_JOB_INFO};
        $self->{+SHOW_RUN_INFO}   = 0 unless defined $self->{+SHOW_RUN_INFO};
        $self->{+SHOW_JOB_LAUNCH} = 0 unless defined $self->{+SHOW_JOB_LAUNCH};
        $self->{+SHOW_JOB_END}    = 1 unless defined $self->{+SHOW_JOB_END};

        $self->{+ENV_VARS}->{HARNESS_IS_VERBOSE} = 0;
        $self->{+ENV_VARS}->{T2_HARNESS_IS_VERBOSE} = 0;
    }

    unless(defined $self->{+UNSAFE_INC}) {
        if (defined $ENV{PERL_USE_UNSAFE_INC}) {
            $self->{+UNSAFE_INC} = $ENV{PERL_USE_UNSAFE_INC};
        }
        else {
            $self->{+UNSAFE_INC} = 1;
        }
    }

    $tmp_dir ||= $ENV{TMPDIR} || $ENV{TEMPDIR} || File::Spec->tmpdir;

    $self->{+DIR} = tempdir("yath-test-$$-XXXXXXXX", CLEANUP => !$self->{+KEEP_DIR}, DIR => $tmp_dir);
}

sub run {
    my $self = shift;

    if ($self->{+HELP}) {
        print $self->usage;
        exit 0;
    }

    if ($self->{+SHOW_OPTS}) {
        require Test2::Harness::Util::JSON;

        my $data = {%$self};
        delete $data->{+ARGS};

        $data->{+INPUT} = '<TRUNCATED>'
            if $data->{+INPUT} && length($data->{+INPUT}) > 80 || $data->{+INPUT} =~ m/\n/;

        print Test2::Harness::Util::JSON::encode_pretty_json($data);

        return 0;
    }

    my $run = Test2::Harness::Run->new(
        run_id     => $self->{+RUN_ID},
        job_count  => $self->{+JOB_COUNT},
        switches   => $self->{+SWITCHES},
        libs       => $self->{+LIBS},
        lib        => $self->{+LIB},
        blib       => $self->{+BLIB},
        preload    => $self->{+PRELOAD},
        args       => $self->{+TEST_ARGS},
        input      => $self->{+INPUT},
        chdir      => $self->{+CHDIR},
        search     => $self->{+SEARCH},
        unsafe_inc => $self->{+UNSAFE_INC},
        env_vars   => $self->{+ENV_VARS},
        no_stream  => $self->{+NO_STREAM},
        no_fork    => $self->{+NO_FORK},
    );

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $self->{+DIR},
        run => $run,
    );

    my $pid = $runner->spawn;

    my $feeder = Test2::Harness::Feeder::Run->new(
        run    => $run,
        runner => $runner,
        dir    => $self->{+DIR},
    );

    my $loggers = [];
    if ($self->{+LOG}) {
        my $file = $self->{+LOG_FILE};

        my $log_fh;
        if ($self->{+BZIP2_LOG}) {
            $file = $self->{+LOG_FILE} = "$file.bz2";
            $log_fh = IO::Compress::Bzip2->new($file) or die "IO::Compress::Bzip2 failed: $Bzip2Error\n";
        }
        elsif ($self->{+GZIP_LOG}) {
            $file = $self->{+LOG_FILE} = "$file.gz";
            $log_fh = IO::Compress::Gzip->new($file) or die "IO::Compress::Bzip2 failed: $GzipError\n";
        }
        else {
            $log_fh = open_file($file, '>');
        }

        require Test2::Harness::Logger::JSONL;
        push @$loggers => Test2::Harness::Logger::JSONL->new(fh => $log_fh);
    }

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
        run_id            => $self->{+RUN_ID},
        live              => 1,
        feeder            => $feeder,
        loggers           => $loggers,
        renderers         => $renderers,
        event_timeout     => $self->{+EVENT_TIMEOUT},
        post_exit_timeout => $self->{+POST_EXIT_TIMEOUT},
    );

    my $queue_file = $runner->queue_file;
    sleep 0.02 until -e $queue_file;
    for my $file ($run->find_files) {
        $runner->enqueue({file => $file});
    }
    $runner->end_queue;

    my $stat = $harness->run();

    $runner->wait;
    my $exit = $runner->exit;

    print "\n", '=' x 80, "\n";
    print "\nRun ID: $self->{+RUN_ID}\n";

    print "\nTest runner exited badly: $exit\n" if $exit;

    my $bad = $stat->{fail};
    if (@$bad) {
        print "\nThe following test jobs failed:\n";
        print "  [", $_->{job_id}, '] ', $_->file, "\n" for sort { $a->{job_id} <=> $b->{job_id} } @$bad;
        print "\n";
        $exit += @$bad;
    }
    else {
        print "\nAll tests were successful!\n\n";
    }

    print "Keeping work dir: $self->{+DIR}\n" if $self->{+KEEP_DIR};

    print "Wrote log file: $self->{+LOG_FILE}\n"
        if $self->{+LOG_FILE};

    $exit = 255 if $exit > 255;

    return $exit;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::test - Command to run tests

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
