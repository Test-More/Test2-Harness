package App::Yath::Command::test::Options;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Util qw/clean_path/;
use Test2::Util qw/IS_WIN32/;

use App::Yath::Options;

# Yath    - The interface that ties everything together. This is the part that
#           people interact with. This is also reponsible for display.
#
# Harness - runs in front, the part that reads all the output from the tests
#           that are running and determines if it is passing or failing. Also
#           has the role of watching things and killing them if it goes wonky.
#
# Runner  - does the work of actually executing the tests and making sure their
#           effects/output/results etc go to the harness (or where the harness
#           can find them)
#
# Run     - A set of jobs to be run
#
# Job     - Lives under runner, a single specific job


# Process
# Yath reads command line args and executes command
# Command (assume test) does:
#  * Starts a runner                                    - 'start' command does *just* this
#  * Defines a run for the runner                       - 'run' command does this and all following ones
#  * Starts a harness
#  * Reads events from the harness and renders them
#  * Reports results

sub fields_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    my $fields = ${$slot} //= [];

    if ($norm =~ m/^{/) {
        my $field = {};
        my $ok    = eval { $field = Test2::Harness::Util::JSON::decode_json($norm); 1 };
        chomp(my $error = $@ // '');

        die "Error parsing field specification '$field': $error\n" unless $ok;
        die "Fields must have a 'name' key (error in '$raw')\n"    unless $field->{name};
        die "Fields must habe a 'details' key (error in '$raw')\n" unless $field->{details};

        return push @$fields => $field;
    }
    elsif ($norm =~ m/([^:]+):([^:]+)/) {
        return push @$fields => {name => $1, details => $2};
    }

    die "'$raw' is not a valid field specification.\n";
}

sub author_testing_post_process {
    my %params   = @_;
    my $settings = $params{settings};
    $settings->{job}->{env_vars}->{AUTHOR_TESTING} = 1 if $settings->{job}->{'author-testing'};
}

option_group {prefix => 'harness', category => "Harness Options"} => sub {
    option keep_dir => (
        short       => 'k',
        description => 'Do not delete the work directory when done. This is useful if you want to inspect the work directory after the harness is done. The work directory path will be printed at the end.',
        default     => 0,
    );
};

option_group {prefix => 'display', category => "Display Options"} => sub {
    option color => (
        description => "Turn color on, default is true if STDOUT is a TTY.",
        default     => sub { -t STDOUT ? 1 : 0 },
    );

    option quiet => (
        short       => 'q',
        description => "Be very quiet.",
        default     => 0,
    );

    option verbose => (
        short       => 'v',
        type        => 'c',
        description => "Be more verbose",
        default     => 0,
    );

    option show_times => (
        short       => 'T',
        description => 'Show the timing data for each job',
    );
};

option_group {prefix => 'run', category => "Run Options"} => sub {
    option libs => (
        name        => 'include',
        short       => 'I',
        type        => 'm',
        description => "Add a directory to your include paths",
        normalize   => \&clean_path,
    );

    option tlib => (
        description => "(Default: off) Include 't/lib' in your module path",
        default     => 0,
    );

    option lib => (
        description => "(Default: on) Include 'lib' in your module path",
        default     => 1,
    );

    option blib => (
        description => "(Default: on) Include 'blib/lib' and 'blib/arch' in your module path",
        default     => 1,
    );

    option input => (
        type        => 's',
        description => 'Input string to be used as standard input for ALL tests. See also: --input-file',
    );

    option author_testing => (
        short        => 'A',
        description  => 'This will set the AUTHOR_TESTING environment to true',
        post_process => \&author_testing_post_process,
    );

    option use_stream => (
        name        => 'stream',
        description => "Use the stream formatter (default is on)",
        default     => 1,
    );

    option tap => (
        field       => 'use_stream',
        alt         => ['TAP', '--no-stream'],
        normalize   => sub { $_[0] ? 0 : 1 },
        description => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests wh    ere this causes problems, in which case setting --TAP or --no-stream can help."
    );

    option fields => (
        type           => 'm',
        short          => 'f',
        long_examples  => [' name:details', ' JSON_STRING'],
        short_examples => [' name:details', ' JSON_STRING'],
        description    => "Add custom data to the harness run",
        action         => \&fields_action,
    );
};

option_group {prefix => 'runner', category => "Runner Options"} => sub {
    option fork => (
        field => 'use_fork',
        description => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' coment in their header to disable forking only for those tests.",
        default => sub { !IS_WIN32 },
    );

    option cover => (
        field => 'cover',
        description => 'Use Devel::Cover to calculate test coverage. This disables forking',
        post_process => \&cover_post_process,
    );
};

sub cover_post_process {
    my %params   = @_;
    my $settings = $params{settings};

    $settings->{runner}->{use_fork} = 0 if $settings->{runner}->{cover};
}

1;

__END__

        {
            spec => 'cover',
            field => 'cover',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage => ['--cover'],
            summary => ['use Devel::Cover to calculate test coverage'],
            action => sub {
                my $self = shift;
                my ($settings) = @_;
                eval { require Devel::Cover; 1 } or die "Cannot use --cover without Devel::Cover: $@";
                $settings->{cover} = 1;
                $settings->{use_fork} = 0;
                push @{$settings->{load_import} ||= []} => 'Devel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
            },
            long_desc => "This is essentially the same as combining: '--no-fork', and '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl' Devel::Cover and preload/fork do not work well together.",
        },

        {
            spec      => 'unsafe-inc!',
            field     => 'unsafe_inc',
            used_by   => {jobs => 1, runner => 1},
            section   => 'Job Options',
            usage     => ['--unsafe-inc', '--no-unsafe-inc'],
            summary   => ["(Default: On) put '.' in \@INC", "Do not put '.' in \@INC"],
            long_desc => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
            default   => sub {
                return $ENV{PERL_USE_UNSAFE_INC} if defined $ENV{PERL_USE_UNSAFE_INC};
                return 1;
            },
            normalize => sub { $_[3] ? 1 : 0 },
        },

        {
            spec    => 'input-file=s',
            field   => 'input',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            action  => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                die "Input file not found: $arg\n" unless -f $arg;
                warn "Input file is overriding another source of input.\n" if $settings->{input};
                $settings->{input} = read_file($arg);
            },
            usage   => ['--input-file file'],
            summary => ['Use the specified file as standard input to ALL tests'],
        },

        {
            spec    => 'E|env-var=s',
            field   => 'env_vars',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            action  => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                my ($key, $val) = split /=/, $arg, 2;
                $settings->{env_vars}->{$key} = $val;
            },
            usage   => ['-E VAR=value',                              '--env-var VAR=val'],
            summary => ['Set an environment variable for each test', '(but not the harness)'],
            default => sub                                           { {} },
        },

        {
            spec    => 'S|switch=s',
            field   => 'switches',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            action  => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                my ($switch, $val) = split /=/, $arg, 2;
                push @{$settings->{switches}} => $switch;
                push @{$settings->{switches}} => $val if defined $val;
            },
            usage     => ['-S SW  -S SW=val', '--switch SW=val'],
            summary   => ['Pass the specified switch to perl for each test'],
            long_desc => 'This is not compatible with preload.',
        },

        {
            spec    => 'C|clear!',
            field   => 'clear_dir',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-C  --clear'],
            summary => ['Clear the work directory if it is not already empty'],
        },

        {
            spec => 'shm!',
            field => 'use_shm',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage => ['--shm', '--no-shm'],
            summary => ["Use shm for tempdir if possible (Default: off)", "Do not use shm."],
            default => 0,
        },

        {
            spec    => 't|tmpdir=s',
            field   => 'tmp_dir',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-t path/', '--tmpdir path/'],
            summary => ['Use a specific temp directory', '(Default: use system temp dir)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                if ($settings->{use_shm}) {
                    $settings->{tmp_dir} = first { -d $_ } map { File::Spec->canonpath($_) } '/dev/shm', '/run/shm';
                }
                return $settings->{tmp_dir} ||= $ENV{TMPDIR} || $ENV{TEMPDIR} || File::Spec->tmpdir;
            },
        },

        {
            spec => 'D|dummy',
            field   => 'dummy',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-D', '--dummy'],
            summary => ['Dummy run, do not actually execute tests'],
            default => $ENV{T2_HARNESS_DUMMY} || 0,
        },

        {
            spec    => 'd|dir|workdir=s',
            field   => 'dir',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-d path', '--dir path', '--workdir path'],
            summary => ['Set the work directory', '(Default: new temp directory)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                return $ENV{T2_WORKDIR} if $ENV{T2_WORKDIR};
                return tempdir("yath-test-$$-XXXXXXXX", CLEANUP => !($settings->{keep_dir} || $self->always_keep_dir), DIR => $settings->{tmp_dir});
            },
            normalize => sub { File::Spec->rel2abs($_[3]) },
        },

        {
            spec    => 'no-long',
            field   => 'no_long',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['--no-long'],
            summary => ["Do not run tests with the HARNESS-DURATION-LONG header"],
        },

        {
            spec    => 'only-long',
            field   => 'only_long',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['--only-long'],
            summary => ["only run tests with the HARNESS-DURATION-LONG header"],
        },

        {
            spec => 'durations=s',
            field => 'durations',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage => ['--durations path', '--durations url'],
            long_desc => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
        },

        {
            spec => 'maybe-durations=s@',
            field => 'maybe_durations',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage => ['--maybe-durations path', '--maybe-durations url'],
            long_desc => "Same as 'durations' except not fatal if not found. If this and 'durations' are both specified then 'durations' is used as a fallback when this fails. You may specify this option multiple times and the first one that works will be used"
        },

        {
            spec    => 'x|exclude-file=s@',
            field   => 'exclude_files',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-x t/bad.t', '--exclude-file t/bad.t'],
            summary => ["Exclude a file from testing", "May be specified multiple times"],
            default => sub { [] },
        },

        {
            spec    => 'X|exclude-pattern=s@',
            field   => 'exclude_patterns',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-X foo', '--exclude-pattern bar'],
            summary => ["Exclude files that match", "May be specified multiple times", "matched using `m/\$PATTERN/`"],
            default => sub { [] },
        },

        {
            spec    => 'id|run-id=s',
            field   => 'run_id',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['--id ID',               '--run_id ID'],
            summary => ['Set a specific run-id', '(Default: a UUID)'],
            default => sub                       { gen_uuid() },
        },

        {
            spec    => 'j|jobs|job-count=i',
            field   => 'job_count',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-j #  --jobs #', '--job-count #'],
            summary => ['Set the number of concurrent jobs to run', '(Default: 1)'],
            default => 1,
        },

        {
            spec    => 'P|preload=s@',
            field   => 'preload',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-P Module', '--preload Module'],
            summary => ['Preload a module before running tests', 'this option may be given multiple times'],
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                push @{$settings->{preload}}, $arg;
            },
        },

        {
            spec => 'no-preloads',
            field => 'preload',
            used_by => { runner => 1 },
            section => 'Harness Options',
            usage => ['--no-preload'],
            summary => ['cancel any preloads listed until now'],
            long_desc => "This can be used to negate preloads specified in .yath.rc or similar",
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;
                delete $settings->{preload};
            },
        },

        {
            spec    => 'm|load|load-module=s@',
            field   => 'load',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-m Module', '--load Module', '--load-module Mod'],
            summary => ['Load a module in each test (after fork)', 'this option may be given multiple times'],
        },

        {
            spec    => 'M|loadim|load-import=s@',
            field   => 'load_import',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-M Module', '--loadim Module', '--load-import Mod'],
            summary => ['Load and import module in each test (after fork)', 'this option may be given multiple times'],
        },


        {
            spec      => 'et|event_timeout=i',
            field     => 'event_timeout',
            used_by   => {jobs => 1},
            section   => 'Harness Options',
            usage     => ['--et SECONDS', '--event_timeout #'],
            summary   => ['Kill test if no events received in timeout period', '(Default: 60 seconds)'],
            long_desc => 'This is used to prevent the harness for waiting forever for a hung test. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 60,
        },

        {
            spec      => 'pet|post-exit-timeout=i',
            field     => 'post_exit_timeout',
            used_by   => {jobs => 1},
            section   => 'Harness Options',
            usage     => ['--pet SECONDS', '--post-exit-timeout #'],
            summary   => ['Stop waiting post-exit after the timeout period', '(Default: 15 seconds)'],
            long_desc => 'Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exists it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 15,
        },

        {
            spec    => 'L|log',
            field   => 'log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-L', '--log'],
            summary => ['Turn on logging'],
            default => sub {
                my ($self, $settings) = @_;
                return 1 if $settings->{log_file} || $settings->{log_file_format} || exists $ENV{YATH_LOG_FILE_FORMAT};
                return 1 if $settings->{bzip2_log};
                return 1 if $settings->{gzip_log};
                return 0;
            },
        },

        {
            spec    => 'lff|log-file-format=s',
            field   => 'log_file_format',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['--lff format-string', '--log-file-format ...'],
            summary => ['Specify the format for automatically-generated log files.', 'Overridden by --log-file, if given',
                        'This option implies -L', "(Default: \$YATH_LOG_FILE_FORMAT, if that is set, or else '%Y-%m-%d~%H:%M:%S~%!U~%!p.jsonl')"],
            long_desc => "This is a string in which percent-escape sequences will be replaced as per POSIX::strftime.  The following special escape sequences are also replaced: (%!U : the unique test run ID)  (%!p : the process ID) (%!S : the number of seconds since local midnight UTC ",
            default   => sub {
                my ($self, $settings) = @_;
                return unless $settings->{log};
                return defined($ENV{YATH_LOG_FILE_FORMAT}) ? $ENV{YATH_LOG_FILE_FORMAT}
                                                           : '%Y-%m-%d~%H:%M:%S~%!U~%!p.jsonl';
            },
        },

        {
            spec    => 'F|log-file=s',
            field   => 'log_file',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-F file.jsonl', '--log-file FILE'],
            summary => ['Specify the name of the log file', 'This option implies -L', "(Default: event_log-RUN_ID.jsonl)"],
            normalize => sub { File::Spec->rel2abs($_[3]) },
            default   => sub {
                my ($self, $settings, $field) = @_;

                return unless $settings->{bzip2_log} || $settings->{gzip_log} || $settings->{log};

                mkdir('test-logs') or die "Could not create dir 'test-logs': $!"
                    unless -d 'test-logs';

                my $format = $settings->{log_file_format};
                my $filename = $self->expand_log_file_format($format, $settings);
                return File::Spec->catfile('test-logs', $filename);
            },
        },

        {
            spec    => 'B|bz2|bzip2-log',
            field   => 'bzip2_log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-B  --bz2', '--bzip2-log'],
            summary => ['Use bzip2 compression when writing the log', 'This option implies -L', '.bz2 prefix is added to log file name for you'],
        },

        {
            spec    => 'G|gz|gzip-log',
            field   => 'gzip_log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-G  --gz', '--gzip-log'],
            summary => ['Use gzip compression when writing the log', 'This option implies -L', '.gz prefix is added to log file name for you'],
        },

        {
            spec    => 'r|renderer=s@',
            field   => 'renderers',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-r +Module', '-r Postfix', '--renderer ...', '-r +Module=arg1,arg2,...'],
            summary   => ['Specify renderers', '(Default: "Formatter")'],
            long_desc => 'Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument. You may specify custom arguments to the constructor after an "=" sign.',
            default   => sub { $_[1]->{quiet} ? [] : ['+Test2::Harness::Renderer::Formatter'] },
        },

        {
            spec      => 'formatter=s',
            field     => 'formatter',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['--formatter Mod', '--formatter +Mod'],
            summary   => ['Specify the formatter to use', '(Default: "Test2")'],
            long_desc => 'Only useful when a renderer is set to "Formatter". This specified the Test2::Formatter::XXX that will be used to render the test output.',
            default   => sub {
                my ($self, $settings, $field) = @_;

                my $renderers = $settings->{renderers} or return undef;

                my $need_formatter = 0;
                $need_formatter ||= 1 if grep { $_ eq 'Formatter' || $_ eq '+Test2::Harness::Renderer::Formatter'} @$renderers;

                return undef unless $need_formatter;

                return '+Test2::Formatter::Test2';
            },
        },

        {
            spec      => 'show-job-end!',
            field     => 'show_job_end',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['--show-job-end', '--no-show-job-end'],
            summary   => ['Show output when a job ends', '(Default: on)'],
            long_desc => 'This is only used when the renderer is set to "Formatter"',
            default   => 1,
        },

        {
            spec    => 'show-job-info!',
            field   => 'show_job_info',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-job-info', '--no-show-job-info'],
            summary => ['Show the job configuration when a job starts', '(Default: off, unless -vv)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose} > 1;
                return 0;
            },
        },

        {
            spec    => 'show-job-launch!',
            field   => 'show_job_launch',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-job-launch', '--no-show-job-launch'],
            summary => ["Show output for the start of a job", "(Default: off unless -v)"],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose};
                return 0;
            },
        },

        {
            spec    => 'show-run-info!',
            field   => 'show_run_info',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-run-info', '--no-show-run-info'],
            summary => ['Show the run configuration when a run starts', '(Default: off, unless -vv)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose} > 1;
                return 0;
            },
        },
    );
}


