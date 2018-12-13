package App::Yath::Command;
use strict;
use warnings;

our $VERSION = '0.001072';

use Carp qw/croak confess/;
use File::Temp qw/tempdir/;
use Getopt::Long qw/GetOptionsFromArray/;
use File::Path qw/remove_tree/;
use List::Util qw/first max/;
use Test2::Util qw/pkg_to_file IS_WIN32/;
use POSIX qw/strftime/;
use Config qw/%Config/;

use File::Spec;

use Test2::Harness::Util qw/read_file open_file fqmod/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness;
use Test2::Harness::Run;

use Test2::Harness::Util::HashBase qw/-settings -_my_opts -signal -args -plugins -painted/;

sub handle_list_args { () }
sub feeder           { () }
sub cli_args         { () }
sub internal_only    { 0 }
sub has_jobs         { 0 }
sub has_runner       { 0 }
sub has_logger       { 0 }
sub has_display      { 0 }
sub show_bench       { 1 }
sub always_keep_dir  { 0 }
sub name             { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }
sub summary          { "No Summary" }
sub description      { "No Description" }
sub group            { "ZZZZZZ" }
sub run_command      { confess "Not Implemented" }

sub my_opts {
    my $in = shift;
    my %params = @_;

    my $ref = ref($in);

    return $in->{+_MY_OPTS} if $ref && $in->{+_MY_OPTS} && !$params{plugin_options};

    my $settings = $ref ? $in->{+SETTINGS} ||= {} : {};

    my @options = $in->options();
    push @options => @{$params{plugin_options}} if $params{plugin_options};

    my @have;
    push @have => 'jobs'    if $in->has_jobs;
    push @have => 'runner'  if $in->has_runner;
    push @have => 'logger'  if $in->has_logger;
    push @have => 'display' if $in->has_display;
    my $out = [
        grep {
            my $u = $_->{used_by};
            $u->{all} || grep { $u->{$_} } @have
        } @options
    ];

    return $in->{+_MY_OPTS} = $out if $ref;
    return $out;
}

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS} ||= {};

    my $list = $self->parse_args($self->{+ARGS} ||= {});

    $self->normalize_settings();

    # handle --help before the command has a chance
    # to decide that anything might be wrong with the arguments
    if ($settings->{help}) {
        delete $settings->{quiet};
        $self->paint($self->usage);
        return;
    }

    if ($settings->{version}) {
        delete $settings->{quiet};
        $self->paint($self->version_details);
        return;
    }

    die "You cannot select both bzip2 and gzip for the log.\n"
        if $settings->{bzip2_log} && $settings->{gzip_log};

    die "You cannot use preloads with --cover"
        if $settings->{cover} && $settings->{preload} && @{$settings->{preload}};

    die "You cannot use forking with --cover"
        if $settings->{cover} && $settings->{use_fork};

    $self->handle_list_args($list);

    if ($settings->{dir}) {
        remove_tree($settings->{dir}, {safe => 1, keep_root => 1})
            if $settings->{clear_dir} && -d $settings->{dir};

        opendir(my $DH, $settings->{dir}) or die "Could not open directory '$settings->{dir}': $!";
        die "Work directory is not empty (use -C to clear it)" if first { !m/^\.+$/ } readdir($DH);
        closedir($DH);
    }

    for my $plugin (@{$self->{+PLUGINS}}) {
        $plugin->post_init($self, $settings);
    }

    return;
}

sub normalize_settings {
    my $self = shift;

    my $settings = $self->{+SETTINGS} ||= {};

    if (IS_WIN32) {
        die "Fork mode is not supported on windows" if $settings->{fork};
        die "Preload mode is not supported on windows" if $settings->{preload};
    }

    for my $opt (@{$self->my_opts}) {
        my $field     = $opt->{field};
        my $default   = $opt->{default};
        my $action    = $opt->{action};
        my $normalize = $opt->{normalize};

        unless($field) {
            die "You cannot specify 'default' without 'field' for option '$opt->{spec}'" if defined $default;
            die "You cannot specify 'normalize' without 'field' for option '$opt->{spec}'" if defined $normalize;
            next;
        }

        # Set the default
        if (defined($default) && !defined($settings->{$field})) {
            my $val = ref($default) ? $self->$default($settings, $field) : $default;
            $settings->{$field} = $val;
        }

        next unless $normalize && defined $settings->{$field};

        # normalize the value
        $settings->{$field} = $self->$normalize($settings, $field, $settings->{$field});

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

    if (my $p5lib = $ENV{PERL5LIB}) {
        my $libs = $settings->{libs} ||= [];
        my $sep = $Config{path_sep};
        push @$libs => map { File::Spec->rel2abs($_) } split /\Q$sep\E/, $p5lib;
    }

    if (my $s = $ENV{HARNESS_PERL_SWITCHES}) {
        push @{$settings->{switches}} => split /\s+/, $s;
    }

    $settings->{env_vars}->{HARNESS_IS_VERBOSE}    = $settings->{verbose} ? 1 : 0;
    $settings->{env_vars}->{T2_HARNESS_IS_VERBOSE} = $settings->{verbose} ? 1 : 0;
}

sub run {
    my $self = shift;

    my $exit = $self->pre_run();
    return $exit if defined $exit;

    $exit = $self->run_command();
    return $exit;
}

sub pre_run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    if ($settings->{show_opts}) {
        require Test2::Harness::Util::JSON;

        $settings->{input} = '<TRUNCATED>'
            if $settings->{input} && (length($settings->{input}) > 80 || $settings->{input} =~ m/\n/);

        my $out = Test2::Harness::Util::JSON::encode_pretty_json($settings);
        delete $settings->{quiet};
        $self->paint($out);

        return 0;
    }

    # init() will already have printed the help message
    # so there is nothing more to do
    return 0 if $settings->{help} || $settings->{version};

    $self->inject_signal_handlers();

    return;
}


sub paint {
    my $self = shift;
    push @{$self->{+PAINTED}} => @_;
    return if $self->{+SETTINGS}->{quiet};
    print @_;
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
        search      => $settings->{search},
        unsafe_inc  => $settings->{unsafe_inc},
        env_vars    => $settings->{env_vars},
        use_stream  => $settings->{use_stream},
        use_fork    => $settings->{use_fork},
        times       => $settings->{times},
        show_times  => $settings->{show_times},
        verbose     => $settings->{verbose},
        no_long     => $settings->{no_long},
        dummy       => $settings->{dummy},
        cover       => $settings->{cover},
        event_uuids => $settings->{event_uuids},
        mem_usage   => $settings->{mem_usage},
        default_search => $settings->{default_search},

        plugins => $self->{+PLUGINS} ? [@{$self->{+PLUGINS}}] : undef,

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
            spec    => 'V|version',
            field   => 'version',
            used_by => {all => 1},
            section => 'Help',
            usage   => ['-V --version'],
            summary => ['Show version information'],
        },

        {
            spec    => 'I|include=s@',
            field   => 'libs',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['-I path/lib',                           '--include lib/'],
            summary   => ['Add a directory to your include paths', 'This can be used multiple times'],
            normalize => sub {
                [map { File::Spec->rel2abs($_) } @{$_[3] || []}];
            },
        },

        {
            spec      => 'T|show-times',
            field     => 'show_times',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['-T  --show-times'],
            summary   => ['Show the timing data for each job'],
        },


        {
            spec      => 'times!',
            field     => 'times',
            used_by   => {jobs => 1, runner => 1},
            section   => 'Job Options',
            usage     => ['-T  --times'],
            summary   => ['Monitor timing data for each test file'],
            long_desc => 'This tells perl to load Test2::Plugin::Times before starting each test.',
            default   => 1,
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
            spec    => 'input=s',
            field   => 'input',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage   => ['-i "string"'],
            summary => ['This input string will be used as standard input for ALL tests', 'See also --input-file'],
        },

        {
            spec      => 'k|keep-dir!',
            field     => 'keep_dir',
            used_by   => {jobs => 1, runner => 1},
            section   => 'Job Options',
            usage     => ["-k  --keep-dir"],
            summary   => ['Do not delete the work directory when done'],
            long_desc => 'This is useful if you want to inspect the work directory after the harness is done. The work directory path will be printed at the end.',
            default   => 0,
        },

        {
            spec    => 'A|author-testing!',
            action  => sub {
                my $self = shift;
                my ($settings, $field, $val) = @_;
                $settings->{env_vars}->{AUTHOR_TESTING} = $val;
            },
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['-A', '--author-testing', '--no-author-testing'],
            summary   => ['This will set the AUTHOR_TESTING environment to true'],
            long_desc => 'Many cpan modules have tests that are only run if the AUTHOR_TESTING environment variable is set. This will cause those tests to run.',
        },

        {
            spec    => 'tap',
            field   => 'use_stream',
            action  => sub { $_[1]->{use_stream} = 0 },
            used_by => {jobs => 1, runner => 1},
        },

        {
            spec    => 'stream!',
            field   => 'use_stream',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['--stream',                                          '--no-stream',       '--TAP  --tap'],
            summary   => ["Use 'stream' instead of TAP (Default: use stream)", "Do not use stream", "Use TAP"],
            long_desc => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.",
            default   => 1,
        },

        {
            spec    => 'fork!',
            field   => 'use_fork',
            used_by => {jobs => 1, runner => 1},
            section => 'Job Options',
            usage     => ['--fork',                            '--no-fork'],
            summary   => ['(Default: on) fork to start tests', 'Do not fork to start tests'],
            long_desc => 'Test2::Harness normally forks to start a test. Forking can break some select tests, this option will allow such tests to pass. This is not compatible with the "preload" option. This is also significantly slower. You can also add the "# HARNESS-NO-PRELOAD" comment to the top of the test file to enable this on a per-test basis.',
            default   => !IS_WIN32,
        },

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
            spec    => 'p|plugin=s@',
            used_by => { all => 1},
            section => 'Plugins',
            usage   => ['-pPlugin', '-p+My::Plugin', '--plugin Plugin'],
            summary => ['Load a plugin', 'can be specified multiple times'],
            action  => sub {},
        },

        {
            spec      => 'no-plugins',
            used_by   => { all => 1 },
            section   => 'Plugins',
            usage     => ['--no-plugins'],
            summary   => ['cancel any plugins listed until now'],
            long_desc => "This can be used to negate plugins specified in .yath.rc or similar",
            action    => sub {},
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
            usage   => ['--lff format-string', '--log-file-format format-string'],
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
            spec    => 'color!',
            field   => 'color',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--color', '--no-color'],
            summary => ["Turn color on (Default: on)", "Turn color off"],
            default => 1,
        },

        {
            spec    => 'q|quiet!',
            field   => 'quiet',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-q', '--quiet'],
            summary => ["Be very quiet"],
            default => 0,
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
# }}}

sub parse_args {
    my $self = shift;
    my ($args) = @_;

    my $opts    = $args->{opts}    || [];
    my $list    = $args->{list}    || [];
    my $plugins = $args->{plugins} || [];

    my $settings = $self->{+SETTINGS} ||= {};
    $settings->{pass} = $args->{pass} || [];

    my @plugin_options;
    for my $plugin (@$plugins) {
        $plugin = fqmod('App::Yath::Plugin', $plugin);
        my $file = pkg_to_file($plugin);
        eval { require $file; 1 } or die "Could not load plugin '$plugin': $@";

        $plugin = $plugin->new if $plugin->can('new');

        push @plugin_options => $plugin->options($self, $settings);
        $plugin->pre_init($self, $settings);
    }

    $self->{+PLUGINS} = $plugins;

    my @opt_map = map {
        my $spec  = $_->{spec};
        my $action = $_->{action};
        my $field = $_->{field};
        if ($action) {
            my $inner = $action;

            $action = sub {
                my ($opt, $val) = @_;
                return $self->$inner($settings, $field, $val, $opt)
            };
        }
        elsif ($field) {
            $action = \($settings->{$field});
        }

        ($spec => $action)
    } @{$self->my_opts(plugin_options => \@plugin_options)};

    Getopt::Long::Configure("bundling");
    my $args_ok = GetOptionsFromArray($opts => @opt_map)
        or die "Could not parse the command line options given.\n";

    return [grep { defined($_) && length($_) } @$opts, @$list];
}

sub usage_opt_order {
    my $self = shift;

    my $idx = 1;
    my %lookup = map {($_ => $idx++)} $self->section_order;

    #<<< no-tidy
    return sort {
          ($lookup{$a->{section}} || 99) <=> ($lookup{$b->{section}} || 99)  # Sort by section first
            or ($a->{long_desc} ? 2 : 1) <=> ($b->{long_desc} ? 2 : 1)       # Things with long desc go to bottom
            or      lc($a->{usage}->[0]) cmp lc($b->{usage}->[0])            # Alphabetical by first usage example
            or       ($a->{field} || '') cmp ($b->{field} || '')             # By field if present
    } grep { $_->{section} } @{$self->my_opts};
    #>>>
}

sub usage_pod {
    my $in = shift;
    my $name = $in->name;

    my @list = $in->usage_opt_order;

    my $out = "";

    my @cli_args = $in->cli_args;
    @cli_args = ('') unless @cli_args;

    for my $args (@cli_args) {
        $out .= "\n    \$ yath $name [options]";
        $out .= " $args" if $args;
        $out .= "\n";
    }

    my $section = '';
    for my $opt (@list) {
        my $sec = $opt->{section};
        if ($sec ne $section) {
            $out .= "\n=back\n" if $section;
            $section = $sec;
            $out .= "\n=head2 $section\n";
            $out .= "\n=over 4\n";
        }

        for my $way (@{$opt->{usage}}) {
            my @parts = split /\s+-/, $way;
            my $count = 0;
            for my $part (@parts) {
                $part = "-$part" if $count++;
                $out .= "\n=item $part\n"
            }
        }

        for my $sum (@{$opt->{summary}}) {
            $out .= "\n$sum\n";
        }

        if (my $desc = $opt->{long_desc}) {
            chomp($desc);
            $out .= "\n$desc\n";
        }
    }

    $out .= "\n=back\n";

    return $out;
}

sub usage {
    my $self = shift;
    my $name = $self->name;

    my @list = $self->usage_opt_order;

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

    @cli_args = ('') unless @cli_args;

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

    $usage =~ s/ +$//gms;

    return $usage;
}

sub version_details {
    my $self = shift;

    require Test2::Util::Table;

    my $out = <<"    EOT";

Yath version: $VERSION

Other version info:
    EOT

    my @vers = (
        [perl => $^V],
        map {eval "require $_;" && [$_ => $_->VERSION]} qw/App::Yath Test2::Harness Test2::Suite Test2::API Test::Builder/
    );

    $out .= join "\n" => Test2::Util::Table::table(
        header => [qw/COMPONENT VERSION/],
        rows   => \@vers,
    );

    return "$out\n\n";
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

    for my $arg (@{$settings->{renderers}}) {
        my ($mod, $args) = split /\s*=\s*/, $arg, 2;
        my %args = defined($args) ? (split /\s*,\s*/, $args) : ();

        $mod = fqmod('Test2::Harness::Renderer', $mod);
        my $pkg_file = pkg_to_file($mod);
        require $pkg_file;

        push @$renderers => $mod->new(
            verbose => $settings->{verbose},
            color   => $settings->{color},
            %args,
            settings => $self->{+SETTINGS},
        );
    }

    return $renderers;
}

sub inject_signal_handlers {
    my $self = shift;

    my $handle_sig = sub {
        my ($sig) = @_;

        $self->{+SIGNAL} = $sig;

        die "Caught SIG$sig. Attempting to shut down cleanly...\n";
    };

    $SIG{INT}  = sub { $handle_sig->('INT') };
    $SIG{TERM} = sub { $handle_sig->('TERM') };
}

sub time_for_strftime { time() }

sub expand_log_file_format {
  my ($self, $pattern, $settings) = @_;
  my %custom_expansion = (U => $settings->{run_id},
                          p => $$,
                          S => $self->time_for_strftime() % 86400,
                         );
  my $before = $pattern;
  $pattern =~ s{%!(\w)}{$self->expand($1, $settings)}ge;
  my $res = strftime($pattern, localtime($self->time_for_strftime()));
  return $res;
}

sub expand {
  my ($self, $letter, $settings) = @_;
  # This could be driven by a hash, but for now if-else is easiest
  if ($letter eq "U") { return $settings->{run_id} }
  elsif ($letter eq "p") { return $$ }
  elsif ($letter eq "S") {
    # Number of seconds since midnight
    my ($s, $m, $h) = (localtime($self->time_for_strftime))[0, 1, 2];
    return sprintf("%05d", $s + 60 * $m + 3600 * $h);
  } else {
    # unrecognized `%!x` expansion.  Should we warn?  Die?
    return "%!$letter";
  }
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
