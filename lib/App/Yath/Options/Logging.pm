package App::Yath::Options::Logging;
use strict;
use warnings;

our $VERSION = '1.000122';

use POSIX qw/strftime/;
use Test2::Harness::Util qw/clean_path/;
use File::Spec;

use App::Yath::Options;

option_group {prefix => 'logging', category => "Logging Options"} => sub {
    option log => (
        short       => 'L',
        description => 'Turn on logging',
    );

    option log_file_format => (
        alt  => ['lff'],
        type => 's',

        env_vars => [qw/YATH_LOG_FILE_FORMAT TEST2_HARNESS_LOG_FORMAT/],
        default => sub { '%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl' },

        description => 'Specify the format for automatically-generated log files. Overridden by --log-file, if given. This option implies -L (Default: \$YATH_LOG_FILE_FORMAT, if that is set, or else "%!P%Y-%m-%d~%H:%M:%S~%!U~%!p.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!P : Project name followed by a ~, if a project is defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)',

    );

    option bzip2 => (
        short        => 'B',
        alt          => ['bz2', 'bzip2_log'],
        description  => 'Use bzip2 compression when writing the log. This option implies -L. The .bz2 prefix is added to log file name for you',
    );

    option gzip => (
        short        => 'G',
        alt          => ['gz', 'gzip_log'],
        description  => 'Use gzip compression when writing the log. This option implies -L. The .gz prefix is added to log file name for you',
    );

    option log_dir => (
        type        => 's',
        normalize   => \&clean_path,
        description => 'Specify a log directory. Will fall back to the system temp dir.',
    );

    option log_file => (
        short        => 'F',
        type         => 's',
        normalize    => \&clean_path,
        description  => "Specify the name of the log file. This option implies -L.",
    );

    post \&post_process;
};

sub post_process {
    my %params   = @_;
    my $settings = $params{settings};
    my $logging  = $settings->logging;

    die "You cannot specify both bzip2-log and gzip-log\n" if $logging->bzip2 && $logging->gzip;

    return unless $logging->log || $logging->bzip2 || $logging->gzip || $logging->log_file;

    # We want to keep the log and put it in a findable location
    $logging->field(log => 1);

    unless ($logging->log_file) {
        my $log_dir = $logging->log_dir // ($settings->check_prefix('workspace') ? $settings->workspace->tmp_dir : File::Spec->tmpdir);

        mkdir($log_dir) or die "Could not create dir '$log_dir': $!"
            unless -d $log_dir;

        my $format   = $logging->log_file_format;
        my $filename = expand_log_file_format($format, $settings);
        $logging->field(log_file => clean_path(File::Spec->catfile($log_dir, $filename)));
    }

    my $log_file = $logging->log_file;
    $log_file =~ s{/+$}{}g;
    $log_file =~ s/\.(gz|bz2)$//;
    $log_file =~ s/\.jsonl?$//;
    $log_file .= "\.jsonl";
    $log_file .= "\.bz2" if $logging->bzip2;
    $log_file .= "\.gz" if $logging->gzip;
    $logging->field(log_file => $log_file);
}

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
    if    ($letter eq "U") { return $settings->run->run_id }
    elsif ($letter eq "p") { return $$ }
    elsif ($letter eq "P") {
        my $project = $settings->harness->project // return "";
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Logging - Logging options for yath

=head1 DESCRIPTION

This is where the command line options for logging are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
