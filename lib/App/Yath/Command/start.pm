package App::Yath::Command::start;
use strict;
use warnings;

our $VERSION = '0.001016';

use File::Spec();

use POSIX ":sys_wait_h";
use Time::HiRes qw/sleep/;

use App::Yath::Util qw/find_pfile PFILE_NAME/;
use Test2::Harness::Util qw/open_file/;

use Test2::Harness::Run::Runner::Persist;
use Test2::Harness::Util::File::JSON;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub has_jobs    { 1 }
sub has_runner  { 1 }
sub has_logger  { 0 }
sub has_display { 0 }
sub always_keep_dir { 1 }
sub manage_runner { 0 }

sub summary { "Start the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
TODO FIX ME
    EOT
}

sub run {
    my $self = shift;

    $self->pre_run();

    if (my $exists = find_pfile()) {
        die "Persistent harness appears to be running, found $exists\n"
    }

    my $settings = $self->{+SETTINGS};
    my $pfile = File::Spec->rel2abs(PFILE_NAME());

    my ($exit, $runner, $pid, $stat);
    my $ok = eval {
        my $run = $self->make_run_from_settings(finite => 0, keep_dir => 1);

        $runner = Test2::Harness::Run::Runner::Persist->new(
            dir => $settings->{dir},
            run => $run,
        );

        my $queue = $runner->queue;
        $queue->start;

        $pid = $runner->spawn(setsid => 1, pfile => $pfile);

        1;
    };
    my $err = $@;

    my $sig = $self->{+SIGNAL};

    print STDERR $err if !$ok && !$sig;
    print STDERR "Received SIG$sig\n" if $sig;

    print "Waiting for runner...\n";

    my $stdout = open_file($runner->out_log);
    my $stderr = open_file($runner->err_log);

    my $check = waitpid($pid, WNOHANG);
    until($runner->ready || $check) {
        while(my $line = <$stdout>) {
            print STDOUT $line;
        }
        while (my $line = <$stderr>) {
            print STDERR $line;
        }
        sleep 0.02;
        $check = waitpid($pid, WNOHANG);
    }

    if ($check != 0) {
        my $exit = $?;
        my $sig = $? & 127;
        $exit >>= 8;
        print STDERR "\nProblem with runner ($pid), waitpid returned $check, exit value: $exit Signal: $sig\n";

        while( my $line = <$stdout> ) {
            print STDOUT $line;
        }
        while (my $line = <$stderr>) {
            print STDERR $line;
        }
    }
    else {
        print "\nPersistent runner started!\n";

        print "Runner PID: $pid\n";
        print "Runner dir: $settings->{dir}\n";
        print "Runner logs:\n";
        print "  standard output: " . $runner->out_log. "\n";
        print "  standard  error: " . $runner->err_log. "\n";
        print "\nUse `yath watch` to monitor the persistent runner\n\n";

        my $data = {
            pid => $pid,
            dir => $settings->{dir},
        };

        Test2::Harness::Util::File::JSON->new(name => $pfile)->write($data);
    }

    return $sig ? 255 : ($exit || 0);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::start

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

    $ yath start [options]

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

=item --shm

=item --no-shm

Use shm for tempdir if possible (Default: on)

Do not use shm.

=item -C

=item --clear

Clear the work directory if it is not already empty

=item -d path

=item --dir path

=item --workdir path

Set the work directory

(Default: new temp directory)

=item -j #

=item --jobs #

=item --job-count #

Set the number of concurrent jobs to run

(Default: 1)

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

=item -P Module

=item --preload Module

Preload a module before running tests

this option may be given multiple times

=item -t path/

=item --tmpdir path/

Use a specific temp directory

(Default: use system temp dir)

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
