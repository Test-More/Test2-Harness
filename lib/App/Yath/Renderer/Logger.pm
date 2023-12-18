package App::Yath::Renderer::Logger;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec;

use POSIX qw/strftime/;

use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::Util::JSON qw/encode_ascii_json/;

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <file
    <gzip
    <bzip2
    <fh
};

use Getopt::Yath;
option_group {group => 'logging', category => "Logging Options", applicable => \&applicable} => sub {
    option dir => (
        prefix      => 'log',
        type        => 'Scalar',
        normalize   => \&clean_path,
        default => sub { File::Spec->tmpdir() },
        description => 'Specify a log directory. Will fall back to the system temp dir.',
    );

    option file_format => (
        prefix => 'log',
        type => 'Scalar',
        alt  => ['lff'],

        from_env_vars => [qw/YATH_LOG_FILE_FORMAT TEST2_HARNESS_LOG_FORMAT/],
        default => '%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl',

        description => 'Specify the format for automatically-generated log files. Overridden by --log-file, if given. This option implies -L (Default: \$YATH_LOG_FILE_FORMAT, if that is set, or else "%!P%Y-%m-%d~%H:%M:%S~%!U~%!p.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!P : Project name followed by a ~, if a project is defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)',
    );

    my $file_trigger = sub {
        my ($opt, %params) = @_;

        if ($params{action} eq 'set') {
            unless ($params{set_from} eq 'autofill') {
                my ($file) = @{$params{val}};
                @{$params{val}} = (1);

                my $field = $opt->field;
                $params{settings}->logging->$field(1) if $field =~ m/zip/;
                $params{settings}->logging->file(normalize_log_file($file, $params{settings})) if $file;
            }
        }
    };

    option log => (
        type        => 'Auto',
        short       => 'L',
        description => 'Turn on logging, optionally set log file name.',
        long_examples => ['', '=logfilename'],
        short_examples => ['', '=logfilename'],
        autofill => sub { 1 },
        trigger => $file_trigger,
    );

    option bzip2 => (
        type        => 'Auto',
        short       => 'B',
        alt         => ['bz2', 'log-bzip2'],

        description => 'Use bzip2 compression when writing the log. Optionally set the log filename.',
        autofill => sub { 1 },
        trigger => sub {
            my ($opt, %params) = @_;
            if ($params{action} eq 'set') {
                die "Cannot enable both bzip2 and gzip for logging.\n" if ${$params{val}}[0] && $params{settings}->logging->gzip;
            }
            $file_trigger->(@_);
        },
    );

    option gzip => (
        type        => 'Auto',
        short       => 'G',
        alt         => ['gz', 'log-gzip'],

        description => 'Use gzip compression when writing the log. This option implies -L. The .gz prefix is added to log file name for you',
        autofill => sub { 1 },
        trigger => sub {
            my ($opt, %params) = @_;
            if ($params{action} eq 'set') {
                die "Cannot enable both bzip2 and gzip for logging.\n" if ${$params{val}}[0] && $params{settings}->logging->bzip2;
            }
            $file_trigger->(@_);
        },
    );

    option auto_ext => (
        type => 'Bool',
        initialize => 1,
        description => "Automatically add .jsonl and .gz/.bz2 file extensions when they are missing from the file name.",
    );

    option file => (
        prefix => 'log',
        type         => 'Scalar',
        short        => 'F',
        description  => "Specify the name of the log file.",
        trigger => sub {
            my ($opt, %params) = @_;

            return unless $params{action} eq 'set';

            my ($file) = @{$params{val}};
            @{$params{val}} = (normalize_log_file($file, $params{settings}));
        },
        default => sub {
            my ($opt, $settings) = @_;

            my $ls = $settings->logging;
            my $dir = $ls->dir;

            mkdir($dir) or die "Could not create dir '$dir': $!"
                unless -d $dir;

            my $format = $ls->file_format;
            my $filename = expand_log_file_format($format, $settings);

            return normalize_log_file(File::Spec->catfile($dir, $filename), $settings);
        },
    );
};

sub args_from_settings {
    my $class = shift;
    my %params = @_;
    return $params{settings}->logging->all;
}

sub start {
    my $self = shift;

    for my $ext ('jsonl', 'jsonl.bz2', 'jsonl.gz') {
        my $n0 = "lastlog.${ext}";
        my $n1 = "lastlog-1.${ext}";

        if (-e $n1 || -l $n1) {
            unlink(clean_path($n1));
            unlink($n1);
        }

        rename($n0, $n1) if -e $n0 || -l $n0;
    }

    my $fh;
    my $file = $self->file;

    if ($self->bzip2) {
        no warnings 'once';
        require IO::Compress::Bzip2;
        $fh = IO::Compress::Bzip2->new($file) or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
    }
    elsif ($self->gzip) {
        no warnings 'once';
        require IO::Compress::Gzip;
        $fh = IO::Compress::Gzip->new($file) or die "Could not open log file '$file': $IO::Compress::Gzip::GzipError";
    }
    else {
        open($fh, '>', $self->{+FILE}) or die "Could not open log file '$self->{+FILE}': $!";
        $fh->autoflush(1);
    }

    $self->{+FH} = $fh;

    print "Opened log file: $file\n";

    my $link = normalize_log_file(lastlog => $self->settings);
    symlink($file => $link) or die "Could not create symlink $file -> $link: $!";

    print "Linked log file: $link\n";
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    print {$self->{+FH}} encode_ascii_json($event), "\n";
}

sub finish {
    my $self = shift;
    my ($auditor) = @_;

    print {$self->{+FH}} "null\n";
    close($self->{+FH});

    print "\nWrote log file: $self->{+FILE}\n";
}

sub weight { -100 }

sub time_for_strftime { time() }

sub expand_log_file_format {
    my ($pattern, $settings) = @_;
    my $before = $pattern;
    $pattern =~ s{%!(\w)}{expand($1, $settings)}ge;
    my $res = strftime($pattern, localtime(time_for_strftime()));
    return $res;
}

sub expand {
    my ($letter, $settings) = @_;
    # This could be driven by a hash, but for now if-else is easiest
    if    ($letter eq "U") { return $settings->maybe(run => 'run_id', 'NO_RUN_ID') }
    elsif ($letter eq "u") { return $ENV{USER} }
    elsif ($letter eq "p") { return $$ }
    elsif ($letter eq "P") {
        my $project = $settings->yath->project // return "";
        return $project . "~";
    }
    elsif ($letter eq "S") {
        # Number of seconds since midnight
        my ($s, $m, $h) = (localtime(time_for_strftime()))[0, 1, 2];
        return sprintf("%05d", $s + 60 * $m + 3600 * $h);
    }
    else {
        # unrecognized `%!x` expansion.  Should we warn?  Die?
        return "%!$letter";
    }
}

sub applicable {
    my ($option, $options) = @_;

    return 1 if $options->have_group('run');
    return 0;
}

sub normalize_log_file {
    my ($filename, $settings) = @_;

    my $ls = $settings->logging;

    if ($ls->auto_ext) {
        $filename .= ".jsonl" unless $filename =~ m/\.jsonl/;
        $filename .= ".bz2" if $ls->bzip2 && $filename !~ m/\.bz2/;
        $filename .= ".gz"  if $ls->gzip  && $filename !~ m/\.gz/;
    }

    return clean_path($filename);
}

1;