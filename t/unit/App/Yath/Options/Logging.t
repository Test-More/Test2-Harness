use Test2::V0;

__END__

package App::Yath::Options::Logging;
use strict;
use warnings;

our $VERSION = '0.001100';

use POSIX qw/strftime/;
use Test2::Harness::Util qw/clean_path/;

use App::Yath::Options;

option_group {prefix => 'logging', category => "Logging Options"} => sub {
    option log => (
        short       => 'L',
        description => 'Turn on logging',
    );

    option log_file_format => (
        alt  => ['lff'],
        type => 's',

        description => 'Specify the format for automatically-generated log files. Overridden by --log-file, if given. This option implies -L (Default: \$YATH_LOG_FILE_FORMAT, if that is set, or else "%Y-%m-%d~%H:%M:%S~%!U~%!p.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)',

        default => sub { $ENV{YATH_LOG_FILE_FORMAT} // '%Y-%m-%d_%H:%M:%S_%!U.jsonl' },
    );

    option bzip2_log => (
        short        => 'B',
        alt          => ['bz2'],
        description  => 'Use bzip2 compression when writing the log. This option implies -L. The .bz2 prefix is added to log file name for you',
        post_process => sub {
            my %params   = @_;
            my $settings = $params{settings};
            my $logging  = $settings->logging;
            die "You cannot specify both bzip2-log and gzip-log\n" if $logging->bzip2_log && $logging->gzip_log;
        },
    );

    option gzip_log => (
        short        => 'G',
        alt          => ['gz'],
        description  => 'Use gzip compression when writing the log. This option implies -L. The .gz prefix is added to log file name for you',
        post_process => sub {
            my %params   = @_;
            my $settings = $params{settings};
            my $logging  = $settings->logging;
            die "You cannot specify both bzip2-log and gzip-log\n" if $logging->bzip2_log && $logging->gzip_log;
        },
    );

    option log_file => (
        alt          => ['F'],
        type         => 's',
        normalize    => \&clean_path,
        description  => "Specify the name of the log file. This option implies -L.",
        post_process => sub {
            my %params   = @_;
            my $settings = $params{settings};
            my $logging  = $settings->logging;

            if ($logging->log || $logging->bzip2_log || $logging->gzip_log) {
                # We want to keep the log and put it in a findable location

                mkdir('test-logs') or die "Could not create dir 'test-logs': $!"
                    unless -d 'test-logs';

                my $format   = $logging->log_file_format;
                my $filename = expand_log_file_format($format, $settings);
                $logging->log_file = clean_path(File::Spec->catfile('test-logs', $filename));
            }

            if ($logging->log_file) {
                $logging->log_file =~ s/\.(gz|bz2)$//;
                $logging->log_file =~ s/\.jsonl?$//;
                $logging->log_file .= "\.jsonl";
                $logging->log_file .= "\.bz2" if $logging->bzip2_log;
                $logging->log_file .= "\.gz" if $logging->gzip_log;
            }
        },
    );
};

sub time_for_strftime { time() }

sub expand_log_file_format {
    my ($pattern, $settings) = @_;
    my %custom_expansion = (
        U => $settings->run->run_id,
        p => $$,
        S => time_for_strftime() % 86400,
    );
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

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
