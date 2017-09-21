package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '0.001016';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase;

sub summary { "Replay a test run from an event log" }

sub group { ' test' }

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 1 }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will re-run the harness against an event log produced by a
previous test run. The only required argument is the path to the log file,
which maybe compressed. Any extra arguments are assumed to be job id's. If you
list any jobs, only listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS};

    my ($log, @jobs) = @$list;

    $settings->{log_file} = $log;
    $settings->{jobs} = { map { $_ => 1 } @jobs} if @jobs;
    $settings->{run_id} ||= 'replay';

    die "You must specify a log file.\n"
        unless $log;

    die "Invalid log file: '$log'"
        unless -f $log;
}

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = Test2::Harness::Feeder::JSONL->new(file => $settings->{log_file});

    return ($feeder);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::replay - Command to replay a test run from an event log.

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

    $ yath replay [options] [--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]

=head2 Help

=over 4

=item --show-opts

Exit after showing what yath thinks your options mean

=item -h

=item --help

Exit after showing this help message

=back

=head2 Harness Options

=over 4

=item --id ID

=item --run_id ID

Set a specific run-id

(Default: current timestamp)

=item --no-long

Do not run tests with the HARNESS-CAT-LONG header

=item -m Module

=item --load Module

=item --load-module Mod

Load a module in each test (after fork)

this option may be given multiple times

=item -M Module

=item --loadim Module

=item --load-import Mod

Load and import module in each test (after fork)

this option may be given multiple times

=item -X foo

=item --exclude-pattern bar

Exclude files that match

May be specified multiple times

matched using `m/$PATTERN/`

=item -x t/bad.t

=item --exclude-file t/bad.t

Exclude a file from testing

May be specified multiple times

=item --et SECONDS

=item --event_timeout #

Kill test if no events received in timeout period

(Default: 60 seconds)

This is used to prevent the harness for waiting forever for a hung test. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.

=item --pet SECONDS

=item --post-exit-timeout #

Stop waiting post-exit after the timeout period

(Default: 15 seconds)

Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exists it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.

=back

=head2 Job Options

=over 4

=item --blib

=item --no-blib

(Default: on) Include 'blib/lib' and 'blib/arch'

Do not include 'blib/lib' and 'blib/arch'

=item --chdir path/

Change to the specified directory before starting

=item --input-file file

Use the specified file as standard input to ALL tests

=item --lib

=item --no-lib

(Default: on) Include 'lib' in your module path

Do not include 'lib'

=item --tlib

(Default: off) Include 't/lib' in your module path

=item -E VAR=value

=item --env-var VAR=val

Set an environment variable for each test

(but not the harness)

=item -i "string"

This input string will be used as standard input for ALL tests

See also --input-file

=item -I path/lib

=item --include lib/

Add a directory to your include paths

This can be used multiple times

=item --fork

=item --no-fork

(Default: on) fork to start tests

Do not fork to start tests

Test2::Harness normally forks to start a test. Forking can break some select tests, this option will allow such tests to pass. This is not compatible with the "preload" option. This is also significantly slower. You can also add the "# HARNESS-NO-PRELOAD" comment to the top of the test file to enable this on a per-test basis.

=item --stream

=item --no-stream

=item --TAP

=item --tap

Use 'stream' instead of TAP (Default: use stream)

Do not use stream

Use TAP

The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.

=item --unsafe-inc

=item --no-unsafe-inc

(Default: On) put '.' in @INC

Do not put '.' in @INC

perl is removing '.' from @INC as a security concern. This option keeps things from breaking for now.

=item -A

=item --author-testing

This will set the AUTHOR_TESTING environment to true

Many cpan modules have tests that are only run if the AUTHOR_TESTING environment variable is set. This will cause those tests to run.

=item -k

=item --keep-dir

Do not delete the work directory when done

This is useful if you want to inspect the work directory after the harness is done. The work directory path will be printed at the end.

=item -S SW

=item -S SW=val

=item --switch SW=val

Pass the specified switch to perl for each test

This is not compatible with preload.

=item -T

=item --times

Monitor timing data for each test file

This tells perl to load Test2::Plugin::Times before starting each test.

=back

=head2 Display Options

=over 4

=item --color

=item --no-color

Turn color on (Default: on)

Turn color off

=item --show-job-info

=item --no-show-job-info

Show the job configuration when a job starts

(Default: off, unless -vv)

=item --show-job-launch

=item --no-show-job-launch

Show output for the start of a job

(Default: off unless -v)

=item --show-run-info

=item --no-show-run-info

Show the run configuration when a run starts

(Default: off, unless -vv)

=item -q

=item --quiet

Be very quiet

=item -v

=item -vv

=item --verbose

Turn on verbose mode.

Specify multiple times to be more verbose.

=item --formatter Mod

=item --formatter +Mod

Specify the formatter to use

(Default: "Test2")

Only useful when the renderer is set to "Formatter". This specified the Test2::Formatter::XXX that will be used to render the test output.

=item --show-job-end

=item --no-show-job-end

Show output when a job ends

(Default: on)

This is only used when the renderer is set to "Formatter"

=item -r +Module

=item -r Postfix

=item --renderer ...

Specify an alternate renderer

(Default: "Formatter")

Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument.

=back

=head2 Plugins

=over 4

=item -pPlugin

=item -p+My::Plugin

=item --plugin Plugin

Load a plugin

can be specified multiple times

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
