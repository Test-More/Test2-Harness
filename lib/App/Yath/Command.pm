package App::Yath::Command;
use strict;
use warnings;

BEGIN {
    my $old = select STDOUT;
    $| = 1;
    select STDERR;
    $| = 1;
    select $old;
}

our $VERSION = '0.001009';

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use Getopt::Long qw/GetOptionsFromArray/;
use File::Path qw/remove_tree/;
use List::Util qw/first max/;
use Test2::Util qw/pkg_to_file/;
use POSIX qw/strftime/;

use File::Spec;

use App::Yath::Util qw/read_config/;
use Test2::Harness::Util qw/read_file open_file fqmod/;
use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

use Test2::Harness;
use Test2::Harness::Run;

use Test2::Harness::Util::HashBase qw/-settings -my_opts -signal -args -plugins/;

sub handle_list_args { }
sub feeder           { }
sub internal_only    { 0 }
sub has_jobs         { 0 }
sub has_runner       { 0 }
sub has_logger       { 0 }
sub has_display      { 0 }
sub show_bench       { 1 }
sub always_keep_dir  { 0 }
sub manage_runner    { 1 }
sub summary          { "No Summary" }
sub name             { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }

sub group { "ZZZZZZ" }

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS} ||= {};

    unshift @{$self->{+ARGS}} => read_config($self->name);

    my $list = $self->parse_args($self->{+ARGS});

    for my $opt (@{$self->{+MY_OPTS}}) {
        my $field   = $opt->{field};
        my $default = $opt->{default};

        # Set the default
        $settings->{$field} = ref($default) ? $self->$default($settings, $field) : $default
            if defined($default) && !defined($settings->{$field});

        # normalize the value
        $settings->{$field} = $opt->{normalize}->($settings->{$field})
            if $opt->{normalize} && defined $settings->{$field};
    }

    if (my $libs = $settings->{libs}) {
        @$libs = map {File::Spec->rel2abs($_)} @$libs;
    }

    if ($settings->{lib}) {
        my $libs = $settings->{libs} ||= [];
        push @$libs => File::Spec->rel2abs('lib');
    }

    if ($settings->{blib}) {
        my $libs = $settings->{libs} ||= [];
        push @$libs => File::Spec->rel2abs('blib/lib');
        push @$libs => File::Spec->rel2abs('blib/arch');
    }

    if ($settings->{tlib}) {
        my $libs = $settings->{libs} ||= [];
        push @$libs => File::Spec->rel2abs('t/lib');
    }

    die "You cannot select both bzip2 and gzip for the log.\n"
        if $settings->{bzip2_log} && $settings->{gzip_log};

    $self->handle_list_args($list);

    if (my $s = $ENV{HARNESS_PERL_SWITCHES}) {
        push @{$settings->{switches}} => split /\s+/, $s;
    }

    $settings->{env_vars}->{HARNESS_IS_VERBOSE}    = $settings->{verbose};
    $settings->{env_vars}->{T2_HARNESS_IS_VERBOSE} = $settings->{verbose};

    if ($settings->{dir}) {
        remove_tree($settings->{dir}, {safe => 1, keep_root => 1})
            if $settings->{clear_dir} && -d $settings->{dir};

        opendir(my $DH, $settings->{dir}) or die "Could not open directory";
        die "Work directory is not empty (use -C to clear it)" if first { !m/^\.+$/ } readdir($DH);
        closedir($DH);
    }

    for my $plugin (@{$self->{+PLUGINS}}) {
        $plugin->post_init($self, $settings);
    }

    return;
}

sub run {
    my $self = shift;

    $self->pre_run();
    $self->run_command();
}

sub pre_run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    if ($settings->{help}) {
        print $self->usage;
        exit 0;
    }

    if ($settings->{show_opts}) {
        require Test2::Harness::Util::JSON;

        $settings->{input} = '<TRUNCATED>'
            if $settings->{input} && (length($settings->{input}) > 80 || $settings->{input} =~ m/\n/);

        print Test2::Harness::Util::JSON::encode_pretty_json($settings);

        exit 0;
    }

    $self->inject_signal_handlers();
}

sub run_command {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

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
    warn $err unless $ok;

    my $exit = 0;

    if ($self->manage_runner) {
        unless ($ok) {
            if ($pid) {
                print STDERR "Killing runner\n";
                kill($self->{+SIGNAL} || 'TERM', $pid);
            }
        }

        if ($runner && $runner->pid) {
            $runner->wait;
            $exit = $runner->exit;
        }
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
        print "  [", $_->{job_id}, '] ', File::Spec->abs2rel($_->file), "\n" for sort {
            my $an = $a->{job_id};
            $an =~ s/\D+//g;
            my $bn = $b->{job_id};
            $bn =~ s/\D+//g;

            # Sort numeric if possible, otherwise string
            int($an) <=> int($bn) || $a->{job_id} cmp $b->{job_id}
        } @$bad;
        print "\n";
        $exit += @$bad;
    }

    if ($fail) {
        my $sig = $self->{+SIGNAL};

        print "\n";

        print "Test runner exited badly: $exit\n" if $exit;
        print "Test runner exited badly: ?\n" unless defined $exit;
        print "An exception was cought\n" if !$ok && !$sig;
        print "Received SIG$sig\n" if $sig;

        print "\n";

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

sub make_run_from_settings {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    return Test2::Harness::Run->new(
        run_id      => $settings->{run_id},
        job_count   => $settings->{job_count},
        switches    => $settings->{switches},
        libs        => $settings->{libs},
        lib         => $settings->{lib},
        blib        => $settings->{blib},
        tlib        => $settings->{tlib},
        preload     => $settings->{preload},
        load        => $settings->{load},
        load_import => $settings->{load_import},
        args        => $settings->{pass},
        input       => $settings->{input},
        chdir       => $settings->{chdir},
        search      => $settings->{search},
        unsafe_inc  => $settings->{unsafe_inc},
        env_vars    => $settings->{env_vars},
        use_stream  => $settings->{use_stream},
        use_fork    => $settings->{use_fork},
        times       => $settings->{times},
        verbose     => $settings->{verbose},
        no_long     => $settings->{no_long},
        plugins     => $settings->{plugins},

        exclude_patterns => $settings->{exclude_patterns},
        exclude_files    => {map { (File::Spec->rel2abs($_) => 1) } @{$settings->{exclude_files}}},

        @_,
    );
}

sub section_order {
    return (
        'Help',
        'Harness Options',
        'Job Options',
        'Logging Options',
        'Display Options',
    );
}

# {{{
sub options {
    my $self = shift;
    my ($settings) = @_;

    return (
        {
            spec    => 'show-opts',
            field   => 'show_opts',
            used_by => {all => 1},
            section => 'Help',
            usage   => ['--show-opts'],
            summary => ['Exit after showing what yath thinks your options mean'],
        },

        {
            spec    => 'h|help',
            field   => 'help',
            used_by => {all => 1},
            section => 'Help',
            usage   => ['-h  --help'],
            summary => ['Exit after showing this help message'],
        },

        {
            spec    => 'I|include=s@',
            field   => 'libs',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['-I path/lib',                           '--include lib/'],
            summary   => ['Add a directory to your include paths', 'This can be used multiple times'],
            normalize => sub {
                [map { File::Spec->rel2abs($_) } @{$_[0] || []}];
            },
        },

        {
            spec      => 'T|times',
            field     => 'times',
            used_by   => {jobs => 1, runner => 1},
            section   => 'Job Options',
            usage     => ['-T  --times'],
            summary   => ['Monitor timing data for each test file'],
            long_desc => 'This tells perl to load Test2::Plugin::Times before starting each test.',
        },

        {
            spec    => 'tlib!',
            field   => 'tlib',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['--tlib'],
            summary => ["(Default: off) Include 't/lib' in your module path"],
            default => 0,
        },

        {
            spec    => 'lib!',
            field   => 'lib',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['--lib',                                           '--no-lib'],
            summary => ["(Default: on) Include 'lib' in your module path", "Do not include 'lib'"],
            default => 1,
        },

        {
            spec    => 'blib!',
            field   => 'blib',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['--blib',                                           '--no-blib'],
            summary => ["(Default: on) Include 'blib/lib' and 'blib/arch'", "Do not include 'blib/lib' and 'blib/arch'"],
            default => 1,
        },

        {
            spec    => 'chdir=s',
            field   => 'chdir',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['--chdir path/'],
            summary => ['Change to the specified directory before starting'],
        },

        {
            spec    => 'input=s',
            field   => 'input',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['-i "string"'],
            summary => ['This input string will be used as standard input for ALL tests', 'See also --input-file'],
        },

        {
            spec      => 'k|keep-dir',
            field     => 'keep_dir',
            used_by   => {jobs => 1, runner => 1},
            section   => 'Job Options',
            usage     => ["-k  --keep-dir"],
            summary   => ['Do not delete the work directory when done'],
            long_desc => 'This is useful if you want to inspect the work directory after the harness is done. The work directory path will be printed at the end.',
            default   => 0,
        },

        {
            spec    => 'A|author-testing',
            action  => sub { $settings->{env_vars}->{AUTHOR_TESTING} = 1 },
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['-A', '--author-testing'],
            summary   => ['This will set the AUTHOR_TESTING environment to true'],
            long_desc => 'Many cpan modules have tests that are only run if the AUTHOR_TESTING environment variable is set. This will cause those tests to run.',
        },

        {
            spec    => 'tap',
            field   => 'use_stream',
            action  => sub { $settings->{use_stream} = 0 },
            used_by => {jobs => 1, runner => 1},
        },

        {
            spec    => 'stream!',
            field   => 'use_stream',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['--stream',                                          '--no-stream',       '--TAP  --tap'],
            summary   => ["Use 'stream' instead of TAP (Default: use stream)", "Do not use stream", "Use TAP"],
            long_desc => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to recieve test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.",
        },

        {
            spec        => 'fork!',
                field   => 'use_fork',
                used_by => {jobs => 1, runner => 1},
                section => 'Job Options',
                usage     => ['--fork',                            '--no-fork'],
                summary   => ['(Default: on) fork to start tests', 'Do not fork to start tests'],
                long_desc => 'Test2::Harness normally forks to start a test. Forking can break some select tests, this option will allow such tests to pass. This is not compatible with the "preload" option. This is also significantly slower. You can also add the "# HARNESS-NO-PRELOAD" comment to the top of the test file to enable this on a per-test basis.',
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
            normalize => sub { $_[0] ? 1 : 0 },
        },

        {
            spec    => 'input-file=s',
            field   => 'input',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            action  => sub {
                my ($opt, $arg) = @_;
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
                my ($opt, $arg) = @_;
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
                my ($opt, $arg) = @_;
                my ($switch, $val) = split /=/, $arg, 2;
                push @{$settings->{switches}} => $switch;
                push @{$settings->{switches}} => $val if defined $val;
            },
            usage     => ['-S SW  -S SW=val', '--switch SW=val'],
            summary   => ['Pass the specified switch to perl for each test'],
            long_desc => 'This is not compatible with preload.',
        },

        {
            spec    => 'C|clear',
            field   => 'clear_dir',
            used_by => {runner => 1},
            section => 'Harness Options',
            usage   => ['-C  --clear'],
            summary => ['Clear the work directory if it is not already empty'],
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
                return $settings->{tmp_dir} ||= $ENV{TMPDIR} || $ENV{TEMPDIR} || File::Spec->tmpdir;
            },
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
                return unless $self->has_runner;
                return $ENV{T2_WORKDIR} if $ENV{T2_WORKDIR};
                return tempdir("yath-test-$$-XXXXXXXX", CLEANUP => !($settings->{keep_dir} || $self->always_keep_dir), DIR => $settings->{tmp_dir});
            },
            normalize => sub { File::Spec->rel2abs($_[0]) },
        },

        {
            spec    => 'no-long',
            field   => 'no_long',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['--no-long'],
            summary => ["Do not run tests with the HARNESS-CAT-LONG header"],
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
            summary => ['Set a specific run-id', '(Default: current timestamp)'],
            default => sub                       { time() },
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
        },

        {
            spec => 'p|plugin=s@',
            field => 'plugins',
            used_by => { all => 1},
            section => 'Plugins',
            usage => ['-pPlugin', '-p+My::Plugin', '--plugin Plugin'],
            summary => ['Load a plugin', 'can be specified multiple times'],
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
            used_by   => {runner => 1},
            section   => 'Harness Options',
            usage     => ['--et SECONDS', '--event_timeout #'],
            summary   => ['Kill test if no events recieved in timeout period', '(Default: 60 seconds)'],
            long_desc => 'This is used to prevent the harness for waiting forever for a hung test. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 60,
        },

        {
            spec      => 'pet|post-exit-timeout=i',
            field     => 'post_exit_timeout',
            used_by   => {runner => 1},
            section   => 'Harness Options',
            usage     => ['--pet SECONDS', '--post-exit-timeout #'],
            summary   => ['Stop waiting post-exit after the timeout period', '(Default: 15 seconds)'],
            long_desc => 'Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exists it will monitor for mor events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 15,
        },

        {
            spec    => 'F|log-file=s',
            field   => 'log_file',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-F file.jsonl', '--log-file FILE'],
            summary => ['Specify the name of the log file', 'This option implies -L', "(Default: event_log-RUN_ID.jsonl)"],
            normalize => sub { File::Spec->rel2abs($_[0]) },
            default   => sub {
                my ($self, $settings, $field) = @_;

                return unless $settings->{bzip2_log} || $settings->{gzip_log} || $settings->{log};

                mkdir('test-logs') or die "Could not create dir 'test-logs': $!"
                    unless -d 'test-logs';

                return File::Spec->catfile('test-logs', strftime("%Y-%m-%d~%H:%M:%S", localtime()). "~$settings->{run_id}~$$.jsonl");
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
            spec    => 'L|log',
            field   => 'log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-L', '--log'],
            summary => ['Turn on logging'],
            default => sub {
                my ($self, $settings) = @_;
                return 1 if $settings->{log_file};
                return 1 if $settings->{bzip2_log};
                return 1 if $settings->{gzip_log};
                return 0;
            },
        },

        {
            spec    => 'color!',
            field   => 'color',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--color', '--no-color'],
            summary => ["Turn color on (Default: on)", "Turn color off"],
            default => 1,
        },

        {
            spec    => 'r|renderer=s',
            field   => 'renderer',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-r +Module', '-r Postfix', '--renderer ...'],
            summary   => ['Specify an alternate renderer', '(Default: "Formatter")'],
            long_desc => 'Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument.',
            default   => '+Test2::Harness::Renderer::Formatter',
        },

        {
            spec    => 'v|verbose+',
            field   => 'verbose',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-v   -vv', '--verbose'],
            summary => ['Turn on verbose mode.', 'Specify multiple times to be more verbose.'],
            default => 0,
        },

        {
            spec      => 'formatter=s',
            field     => 'formatter',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['--formatter Mod', '--formatter +Mod'],
            summary   => ['Specify the formatter to use', '(Default: "Test2")'],
            long_desc => 'Only useful when the renderer is set to "Formatter". This specified the Test2::Formatter::XXX that will be used to render the test output.',
            default   => '+Test2::Formatter::Test2',
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
# }}}

sub parse_args {
    my $self = shift;
    my ($args) = @_;

    my (@opts, @list, @pass, @plugins);

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
        elsif ($last_mark eq '-p' || $last_mark eq '--plugin') {
            $last_mark = '';
            push @plugins => $arg;
        }
        else {
            if ($arg eq '--' || $arg eq '::') {
                $last_mark = $arg;
                next;
            }
            if ($arg eq '-p' || $arg eq '--plugin') {
                $last_mark = $arg;
                next;
            }
            if ($arg =~ m/^(?:-p=?|--plugin=)(.*)$/) {
                push @plugins => $1;
                next;
            }
            push @opts => $arg;
        }
    }

    my $settings = $self->{+SETTINGS} ||= {};
    $settings->{pass} = \@pass;

    my @options = $self->options($settings);

    for my $plugin (@plugins) {
        local $@;
        $plugin = fqmod('App::Yath::Plugin', $plugin);
        my $file = pkg_to_file($plugin);
        eval { require $file; 1 } or die "Could not load plugin '$plugin': $@";

        push @options => $plugin->options($self, $settings);
        $plugin->pre_init($self, $settings);
    }

    $self->{+PLUGINS} = \@plugins;

    my @have;
    push @have => 'jobs'    if $self->has_jobs;
    push @have => 'runner'  if $self->has_runner;
    push @have => 'logger'  if $self->has_logger;
    push @have => 'display' if $self->has_display;
    $self->{+MY_OPTS} = [
        grep {
            my $u = $_->{used_by};
            $u->{all} || grep { $u->{$_} } @have
        } @options
    ];

    my @opt_map = map {
        my $spec  = $_->{spec};
        my $action = $_->{action};
        my $field = $_->{field};
        $action ||= \($settings->{$field}) if $field;

        ($spec => $action)
    } @{$self->{+MY_OPTS}};

    Getopt::Long::Configure("bundling");
    my $args_ok = GetOptionsFromArray(\@opts => @opt_map)
        or die "Could not parse the command line options given.\n";

    return [grep { defined($_) && length($_) } @list, @opts];
}

sub usage {
    my $self = shift;
    my $name = $self->name;

    my $idx = 1;
    my %lookup = map {($_ => $idx++)} $self->section_order;

    #<<< no-tidy
    my @list = sort {
          ($lookup{$a->{section}} || 99) <=> ($lookup{$b->{section}} || 99)  # Sort by section first
            or ($a->{long_desc} ? 2 : 1) <=> ($b->{long_desc} ? 2 : 1)       # Things with long desc go to bottom
            or      lc($a->{usage}->[0]) cmp lc($b->{usage}->[0])            # Alphabetical by first usage example
            or       ($a->{field} || '') cmp ($b->{field} || '')             # By field if present
    } grep { $_->{section} } @{$self->{+MY_OPTS}};
    #>>>

    # Get the longest 'usage' item's length
    my $ul = max(map { length($_) } map { @{$_->{usage}} } @list);

    my $section = '';
    my @options;
    for my $opt (@list) {
        my $sec = $opt->{section};
        if ($sec ne $section) {
            $section = $sec;
            push @options => "  $section:";
        }

        my @set;
        for (my $i = 0; 1; $i++) {
            my $usage = $opt->{usage}->[$i]   || '';
            my $summ  = $opt->{summary}->[$i] || '';
            last unless length($usage) || length($summ);

            my $line = sprintf("    %-${ul}s    %s", $usage, $summ);

            if (length($line) > 80) {
                my @words = grep { $_ } split /(\s+)/, $line;
                my @lines;
                while (@words) {
                    my $prefix = @lines ? (' ' x ($ul + 8)) : '';
                    my $length = length($prefix);

                    shift @words while @lines && @words && $words[0] =~ m/^\s+$/;
                    last unless @words;

                    my @line;
                    while (@words && (!@line || 80 >= $length + length($words[0]))) {
                        $length += length($words[0]);
                        push @line => shift @words;
                    }
                    push @lines => $prefix . join '' => @line;
                }

                push @set => join "\n" => @lines;
            }
            else {
                push @set => $line;
            }
        }
        push @options => join "\n" => @set;

        if (my $desc = $opt->{long_desc}) {
            chomp($desc);

            my @words = grep { $_ } split /(\s+)/, $desc;
            my @lines;
            my $size = 0;
            while (@words && $size != @words) {
                $size = @words;
                my $prefix = '        ';
                my $length = 8;

                shift @words while @lines && @words && $words[0] =~ m/^\s+$/;
                last unless @words;

                my @line;
                while (@words && (!@line || 80 >= $length + length($words[0]))) {
                    $length += length($words[0]);
                    push @line => shift @words;
                }
                push @lines => $prefix . join '' => @line;
            }

            push @options => join("\n" => @lines) . "\n";
        }
    }

    chomp(my @cli_args    = $self->cli_args);
    chomp(my $description = $self->description);

    my $head_common = "$0 $name [options]";
    my $header = join(
        "\n",
        "Usage: $head_common " . shift(@cli_args),
        map { "       $head_common $_" } @cli_args
    );

    my $options = join "\n\n" => @options;

    my $usage = <<"    EOT";

$header

$description

OPTIONS:

$options

    EOT

    return $usage;
}

sub loggers {
    my $self     = shift;
    my $settings = $self->{+SETTINGS};
    my $loggers  = [];

    return $loggers unless $settings->{log};

    my $file = $settings->{log_file};

    my $log_fh;
    if ($settings->{bzip2_log}) {
        $file = $settings->{log_file} = "$file.bz2";
        require IO::Compress::Bzip2;
        $log_fh = IO::Compress::Bzip2->new($file) or die "IO::Compress::Bzip2 failed: $IO::Compress::Bzip2::Bzip2Error\n";
    }
    elsif ($settings->{gzip_log}) {
        $file = $settings->{log_file} = "$file.gz";
        require IO::Compress::Gzip;
        $log_fh = IO::Compress::Gzip->new($file) or die "IO::Compress::Bzip2 failed: $IO::Compress::Gzip::GzipError\n";
    }
    else {
        $log_fh = open_file($file, '>');
    }

    require Test2::Harness::Logger::JSONL;
    push @$loggers => Test2::Harness::Logger::JSONL->new(fh => $log_fh);

    return $loggers;
}

sub renderers {
    my $self      = shift;
    my $settings  = $self->{+SETTINGS};
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
            $f_class = fqmod('Test2::Formatter', $formatter);
            my $file = pkg_to_file($f_class);
            require $file;
        }

        push @$renderers => Test2::Harness::Renderer::Formatter->new(
            show_job_info   => $settings->{show_job_info},
            show_run_info   => $settings->{show_run_info},
            show_job_launch => $settings->{show_job_launch},
            show_job_end    => $settings->{show_job_end},
            formatter       => $f_class->new(verbose => $settings->{verbose}, color => $settings->{color}),
        );
    }
    elsif ($settings->{formatter}) {
        die "The formatter option is only available when the 'Formatter' renderer is in use.\n";
    }
    else {
        my $r_class = fqmod('Test2::Harness::Renderer', $r);
        require $r_class;
        push @$renderers => $r_class->new(verbose => $settings->{verbose}, color => $settings->{color});
    }

    return $renderers;
}

sub inject_signal_handlers {
    my $self = shift;

    my $handle_sig = sub {
        my ($sig) = @_;

        $self->{+SIGNAL} = $sig;

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

App::Yath::Command - Base class for yath commands

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
