package App::Yath::CommandShared::Harness;
use strict;
use warnings;

our $VERSION = '0.001005';

use File::Temp qw/tempdir/;
use IO::Compress::Bzip2 qw/$Bzip2Error/;
use IO::Compress::Gzip qw/$GzipError/;
use Getopt::Long qw/GetOptionsFromArray/;

use App::Yath::Util qw/fully_qualify/;

use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/read_file open_file/;
use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

use Test2::Harness;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/-settings/;

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 0 }
sub extra_opts  {   }
sub feeder      {   }

sub init {
    my $self = shift;

    $self->{+SETTINGS} = $self->parse_args($self->{+ARGS});
    $self->apply_defaults($self->{+SETTINGS});
}

sub parse_args {
    my $self = shift;
    my ($args) = @_;

    my (@opts, @list, @pass);

    my $last_mark = '';
    for my $arg (@{$self->args}) {
        if ($last_mark eq '::') {
            push @pass => $arg;
        }
        elsif ($last_mark eq '--') {
            if ($arg eq '::') {
                $last_mark = $arg;
                next;
            }
            push @list => $arg;
        }
        else {
            if ($arg eq '--' || $arg eq '::') {
                $last_mark = $arg;
                next;
            }
            push @opts => $arg;
        }
    }

    my %settings = ( pass => \@pass );

    Getopt::Long::Configure("bundling");

    # Common, always present
    my $opt_map = [
        'show-opts' => \($settings{show_opts}),
        'h|help'    => \($settings{help}),
        $self->extra_opts,
    ];

    push @$opt_map => (
        'I|include=s@'       => \($settings{libs}),
        'T|times'            => \($settings{times}),
        'b|blib!'            => \($settings{blib}),
        'c|chdir=s'          => \($settings{chdir}),
        'd|dir=s'            => \($settings{dir}),
        'id|run-id=s'        => \($settings{run_id}),
        'i|input=s'          => \($settings{input}),
        'j|jobs|job-count=i' => \($settings{job_count}),
        'k|keep-dir'         => \($settings{keep_dir}),
        'l|lib!'             => \($settings{lib}),
        'p|preload=s@'       => \($settings{preload}),
        't|tmpdir=s'         => \($settings{tmp_dir}),

        'et|event_timeout=i'      => \($settings{event_timeout}),
        'pet|post_exit_timeout=i' => \($settings{post_exit_timeout}),

        'A|author-testing' => sub { $settings{env_vars}->{AUTHOR_TESTING} = 1 },

        'TAP|tap|no-stream' => \($settings{no_stream}),
        'stream'            => sub { $settings{no_stream} = 0 },

        'fork' => sub { $settings{no_fork} = 0 },
        'no-fork' => \($settings{no_fork}),

        'f|input-file=s' => sub {
            my ($opt, $arg) = @_;
            die "Input file not found: $arg\n" unless -f $arg;
            warn "Input file is overriding another source of input.\n" if $settings{input};
            $settings{input} = read_file($arg);
        },

        'E|env-vars=s' => sub {
            my ($opt, $arg) = @_;
            my ($key, $val) = split /=/, $arg, 2;
            $settings{env_vars}->{$key} = $val;
        },

        'S|switch=s' => sub {
            my ($opt, $arg) = @_;
            my ($switch, $val) = split /=/, $arg, 2;
            push @{$settings{switches}} => $switch;
            push @{$settings{switches}} => $val if defined $val;
        },
    ) if $self->has_runner;

    push @$opt_map => (
        'F|log-file=s'    => \($settings{log_file}),
        'L|log'           => \($settings{log}),
        'B|bz2|bzip2-log' => \($settings{bzip2_log}),
        'G|gz|gzip-log'   => \($settings{gzip_log}),
    ) if $self->has_logger;

    push @$opt_map => (
        'r|renderer=s'     => \($settings{renderer}),
        'v|verbose+'       => \($settings{verbose}),
        'formatter=s'      => \($settings{formatter}),
        'show-job-end!'    => \($settings{show_job_end}),
        'show-job-info!'   => \($settings{show_job_info}),
        'show-job-launch!' => \($settings{show_job_launch}),
        'show-run-info!'   => \($settings{show_run_info}),
        'unsafe-inc!'      => \($settings{unsafe_inc}),
    ) if $self->has_display;

    my $args_ok = GetOptionsFromArray(\@opts => @$opt_map)
        or die "Could not parse the command line options given.\n";

    $settings{list} = [ grep { defined($_) && length($_) } @list, @opts ];

    return \%settings;
}

sub apply_defaults {
    my $self = shift;
    my ($settings) = @_;

    if ($self->has_runner) {
        $settings->{search} = delete $settings->{list};

        $settings->{search} = [grep { -e $_ } './t', './t2', 'test.pl']
            unless $settings->{search} && @{$settings->{search}};

        $settings->{run_id}    ||= time;
        $settings->{job_count} ||= 1;
        $settings->{env_vars}  ||= {};

        $settings->{keep_dir} = 0 unless defined $settings->{keep_dir};
        $settings->{lib}      = 1 unless defined $settings->{lib};
        $settings->{blib}     = 1 unless defined $settings->{blib};

        $settings->{event_timeout}     = 60 unless defined $settings->{event_timeout};
        $settings->{post_exit_timeout} = 15 unless defined $settings->{post_exit_timeout};

        unless(defined $settings->{unsafe_inc}) {
            if (defined $ENV{PERL_USE_UNSAFE_INC}) {
                $settings->{unsafe_inc} = $ENV{PERL_USE_UNSAFE_INC};
            }
            else {
                $settings->{unsafe_inc} = 1;
            }
        }

        $settings->{tmp_dir} ||= $ENV{TMPDIR} || $ENV{TEMPDIR} || File::Spec->tmpdir;

        $settings->{dir} = tempdir("yath-test-$$-XXXXXXXX", CLEANUP => !$settings->{keep_dir}, DIR => $settings->{tmp_dir});
    }
    else {
        $settings->{run_id} ||= $self->name;
    }

    if ($self->has_logger) {
        $settings->{log} ||= 1 if $settings->{log_file} || $settings->{bzip2_log} || $settings->{gzip_log};
        $settings->{log_file} ||= "event-log-$settings->{run_id}.jsonl" if $settings->{log};

        die "You cannot select both bzip2 and gzip for the log.\n"
            if $settings->{bzip2_log} && $settings->{gzip_log};
    }

    if ($self->has_display) {
        $settings->{formatter} ||= '+Test2::Formatter::Test2';
        $settings->{renderer}  ||= '+Test2::Harness::Renderer::Formatter';

        if ($settings->{verbose}) {
            $settings->{show_job_info}   = $settings->{verbose} - 1 unless defined $settings->{show_job_info};
            $settings->{show_run_info}   = $settings->{verbose} - 1 unless defined $settings->{show_run_info};
            $settings->{show_job_launch} = 1                        unless defined $settings->{show_job_launch};
            $settings->{show_job_end}    = 1                        unless defined $settings->{show_job_end};

            $settings->{env_vars}->{HARNESS_IS_VERBOSE}    = 1;
            $settings->{env_vars}->{T2_HARNESS_IS_VERBOSE} = 1;
        }
        else {
            # Normalize
            $settings->{verbose} = 0;

            $settings->{show_job_info}   = 0 unless defined $settings->{show_job_info};
            $settings->{show_run_info}   = 0 unless defined $settings->{show_run_info};
            $settings->{show_job_launch} = 0 unless defined $settings->{show_job_launch};
            $settings->{show_job_end}    = 1 unless defined $settings->{show_job_end};

            $settings->{env_vars}->{HARNESS_IS_VERBOSE}    = 0;
            $settings->{env_vars}->{T2_HARNESS_IS_VERBOSE} = 0;
        }
    }
}


sub usage {
    my $self = shift;
    my $name = $self->name;

    chomp(my $cli_args    = $self->cli_args);
    chomp(my $description = $self->description);

    my $usage = <<"    EOT";
Usage: $0 $name [options] $cli_args

$description

OPTIONS:

  Simple:

    --show-opts         Exit after showing what yath thinks your options mean

    -h --help           Exit after showing this help message

    EOT

    $usage .= <<"    EOT" if $self->has_runner;
  Test Runner Options:

    --id 12345          Specify the run-id (Default: current unix time)
    --run_id 12345      Alias for --id

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

    -T --times          Load Test2::Plugin::Times for each test. This will add
                        per-test timing information.

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

    $usage .= <<"    EOT" if $self->has_logger;
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

    EOT

    $usage .= <<"    EOT" if $self->has_display;
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

sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    if ($settings->{help}) {
        print $self->usage;
        return 0;
    }

    if ($settings->{show_opts}) {
        require Test2::Harness::Util::JSON;

        $settings->{input} = '<TRUNCATED>'
            if $settings->{input} && length($settings->{input}) > 80 || $settings->{input} =~ m/\n/;

        print Test2::Harness::Util::JSON::encode_pretty_json($settings);

        return 0;
    }

    $self->inject_signal_handlers(\my $sig);

    my $renderers = $self->renderers;
    my $loggers   = $self->loggers;

    my ($feeder, $runner, $pid, $stat);
    my $ok = eval {
        ($feeder, $runner, $pid) = $self->feeder or die "No feeder!";

        my $harness = Test2::Harness->new(
            run_id            => $settings->{run_id},
            live              => $pid ? 1 : 0,
            feeder            => $feeder,
            loggers           => $loggers,
            renderers         => $renderers,
            event_timeout     => $settings->{event_timeout},
            post_exit_timeout => $settings->{post_exit_timeout},
            jobs              => $settings->{jobs},
        );

        $stat = $harness->run();

        1;
    };
    my $err = $@;

    unless($ok) {
        warn $err;
        if ($pid) {
            print STDERR "Killing runner\n";
            kill($sig || 'TERM', $pid);
        }
    }

    my $exit = 0;
    if ($runner) {
        $runner->wait;
        $exit = $runner->exit;
    }

    if (-t STDOUT) {
        print STDOUT Term::ANSIColor::color('reset') if USE_ANSI_COLOR;
        print STDOUT "\r\e[K";
    }

    if (-t STDERR) {
        print STDERR Term::ANSIColor::color('reset') if USE_ANSI_COLOR;
        print STDERR "\r\e[K";
    }

    print "\n", '=' x 80, "\n";
    print "\nRun ID: $settings->{run_id}\n";

    my $bad = $stat ? $stat->{fail} : [];

    # Possible failure causes
    my $fail = $exit || !defined($exit) || !$ok || !$stat;

    if (@$bad) {
        print "\nThe following test jobs failed:\n";
        print "  [", $_->{job_id}, '] ', $_->file, "\n" for sort { $a->{job_id} <=> $b->{job_id} } @$bad;
        print "\n";
        $exit += @$bad;
    }

    if($fail) {
        print "\n";

        print "Test runner exited badly: $exit\n" if $exit;
        print "Test runner exited badly: ?\n" unless defined $exit;
        print "An exception was cought\n" if !$ok && !$sig;
        print "Received SIG$sig\n" if $sig;

        print "\n";

        $exit = 130 if $sig && $sig eq 'INT';
        $exit = 143 if $sig && $sig eq 'TERM';
        $exit ||= 255;
    }

    if (!@$bad && !$fail) {
        print "\nAll tests were successful!\n\n";
    }

    print "Keeping work dir: $settings->{dir}\n" if $settings->{keep_dir};

    print "Wrote " . ($ok ? '' : '(Potentially Corrupt) ') . "log file: $settings->{log_file}\n"
        if $settings->{log};

    $exit = 255 unless defined $exit;
    $exit = 255 if $exit > 255;

    return $exit;
}

sub loggers {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    my $loggers = [];

    return $loggers unless $settings->{log};

    my $file = $settings->{log_file};

    my $log_fh;
    if ($settings->{bzip2_log}) {
        $file = $settings->{log_file} = "$file.bz2";
        $log_fh = IO::Compress::Bzip2->new($file) or die "IO::Compress::Bzip2 failed: $Bzip2Error\n";
    }
    elsif ($settings->{gzip_log}) {
        $file = $settings->{log_file} = "$file.gz";
        $log_fh = IO::Compress::Gzip->new($file) or die "IO::Compress::Bzip2 failed: $GzipError\n";
    }
    else {
        $log_fh = open_file($file, '>');
    }

    require Test2::Harness::Logger::JSONL;
    push @$loggers => Test2::Harness::Logger::JSONL->new(fh => $log_fh);

    return $loggers;
}

sub renderers {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    my $renderers = [];

    my $r = $settings->{renderer} or return $renderers;

    if ($r eq '+Test2::Harness::Renderer::Formatter' || $r eq 'Formatter') {
        require Test2::Harness::Renderer::Formatter;

        my $formatter = $settings->{formatter} or die "No formatter specified.\n";
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
            show_job_info   => $settings->{show_job_info},
            show_run_info   => $settings->{show_run_info},
            show_job_launch => $settings->{show_job_launch},
            show_job_end    => $settings->{show_job_end},
            formatter       => $f_class->new(verbose => $settings->{verbose}),
        );
    }
    elsif ($settings->{formatter}) {
        die "The formatter option is only available when the 'Formatter' renderer is in use.\n";
    }
    else {
        my $r_class = fully_qualify('Test2::Harness::Renderer', $r);
        require $r_class;
        push @$renderers => $r_class->new(verbose => $settings->{verbose});
    }

    return $renderers;
}

sub inject_signal_handlers {
    my $self = shift;
    my ($sig_ref) = @_;

    my $handle_sig = sub {
        my ($sig) = @_;

        $$sig_ref = $sig;

        die "Cought SIG$sig, Attempting to shut down cleanly...\n";
    };

    $SIG{INT}  = sub { $handle_sig->('INT') };
    $SIG{TERM} = sub { $handle_sig->('TERM') };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::CommandShared::Harness - Common command base for running/rendering
tests

=head1 DESCRIPTION

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
