package App::Yath;
use strict;
use warnings;

our $VERSION = '0.001014';

use App::Yath::Util qw/find_pfile/;

use Time::HiRes qw/time/;

our $SCRIPT;

sub import {
    my $class = shift;
    my ($argv, $runref) = @_ or return;
    my ($pkg, $file, $line) = caller;

    $SCRIPT ||= $file;

    my $cmd_name  = $class->parse_argv($argv);
    my $cmd_class = $class->load_command($cmd_name);
    $cmd_class->import($argv, $runref);

    $$runref ||= sub { $class->run_command($cmd_class, $cmd_name, $argv) };
}

sub info {
    my $class = shift;
    print STDOUT @_;
}

sub run_command {
    my $class = shift;
    my ($cmd_class, $cmd_name, $argv) = @_;

    my $cmd = $cmd_class->new(args => $argv);

    my $start = time;
    my $exit  = $cmd->run;

    die "Command '$cmd_name' did not return an exit value.\n"
        unless defined $exit;

    if ($cmd->show_bench) {
        require Test2::Util::Times;
        my $end = time;
        my $bench = Test2::Util::Times::render_bench($start, $end, times);
        $class->info($bench, "\n\n");
    }

    return $exit;
}

sub parse_argv {
    my $class = shift;
    my ($argv) = @_;

    my $first_not_command = 0;
    if (@$argv) {
        if ($argv->[0] =~ m/^-*h(elp)?$/i) {
            shift @$argv;
            return 'help';
        }

        if ($argv->[0] =~ m/\.jsonl(\.bz2|\.gz)?$/) {
            $class->info("\n** First argument is a log file, defaulting to the 'replay' command **\n\n");
            return 'replay';
        }

        $first_not_command = -d $argv->[0] || -f $argv->[0] || substr($argv->[0], 0, 1) eq '-';
    }

    if (!@$argv || $first_not_command) {
        if (find_pfile) {
            $class->info("\n** Persistent runner detected, defaulting to the 'run' command **\n\n");
            return 'run';
        }

        $class->info("\n** Defaulting to the 'test' command **\n\n");
        return 'test';
    }

    return shift @$argv;
}

sub load_command {
    my $class = shift;
    my ($cmd_name) = @_;

    my $cmd_class  = "App::Yath::Command::$cmd_name";
    my $cmd_file   = "App/Yath/Command/$cmd_name.pm";

    if (!eval { require $cmd_file; 1 }) {
        my $load_error = $@ || 'unknown error';

        die "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)\n"
            if $load_error =~ m{Can't locate \Q$cmd_file\E in \@INC};

        die $load_error;
    }

    return $cmd_class;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath - Yet Another Test Harness (Test2-Harness) Command Line Interface
(CLI)

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

This is the primary documentation for C<yath>, L<App::Yath>, L<Test2::Harness>.

The canonical source of up-to-date command options are the help output when
using C<$ yath help> and C<$ yath help COMMAND>.

This document is mainly for an overview of C<yath> usage, and common recipes.

=head1 OVERVIEW

To use L<Test2::Harness> you use the C<yath> command. Yath will find the tests
(or use the ones you specify), and run them. As it runs it will output
diagnostics information such as failures. At the end yath will print a summary
of the test run.

C<yath> can be thought of as a more powerful alternative to C<prove>
(L<Test::Harness>)

=head1 RECIPES

These are common resipes for using C<yath>.

=head2 RUN PROJECT TESTS

    $ yath

Simply running yath with no arguments means "Run all tests for the current
project". Yath will look for tests in C<./t>, C<./t2>, and C<./test.pl>,
running any that are found.

Normally this implies the C<test> command, but will instead imply the C<run>
command if a persistent test runner is detected.

=head2 PRELOAD MODULES

Yath has the ability to preload modules. Yath normally forks to start new
tests, so preloading can reduce the time spent loading modules over and over in
each test.

Note that some tests may depend on certain modules not being loaded. In these
cases you can add the C<# HARNESS-NO-PRELOAD> directive to the top of the test
files that cannot use preload.

=head3 SIMPLE PRELOAD

Any module can be preloaded:

    $ yath -PMoose

You can preload as many modules as you want:

    $ yath -PList::Util -PScalar::Util

=head3 COMPLEX PRELOAD

If your preload is a subclass of L<Test2::Harness::Preload> then more complex
preload behavior is possible. See the <Test2::Harness::Preload> docs for more
info.

=head2 LOGGING

=head3 RECORDING A LOG

You can turn on logging very easily, the filename of the log will be printed at
the end.

    $ yath -L
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl

The event log can be quite large, it is better to compress it with bzip2

    $ yath -B
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

Or you can use gzip:

    $ yath -G
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.gz

C<-B> and C<-G> both imply C<-L>.

=head3 REPLAYING FROM A LOG

You can replay a test run from a log file:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

This will be significantly faster than the initial run as no tests are actually
being executed. All events are simply read from the log, and processed by the
harness.

You can change display options, and limit rendering/processing to specific test
jobs from the run:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2 -v 5 10

Note: This is done using the C<$ yath replay ...> command. The C<replay>
command is implied if the first argument is a log file.

=head2 PER-TEST TIMING DATA

The C<-T> option will cause each test file to report how long it took to run.

    $ yath -T

    ( PASSED )  job  1    t/App/Yath.t
    (  TIME  )  job  1    0.06942s on wallclock (0.07 usr 0.01 sys + 0.00 cusr 0.00 csys = 0.08 CPU)

=head2 PERSISTENT RUNNER

yath supports starting a yath session that waits for tests to run. This is very
useful if combined with preload.

=head3 STARTING

This starts the server, many options available to the 'test' command will work
here, but not all. See C<$ yath help start> for more info.

    $ yath start

=head3 RUNNING

This will run tests using the persistent runner. By default it will search for
tests just like the 'test' command. Many options available to the C<test>
command will work for this as well. See C<$ yath help run> for more details.

    $ yath run

=head3 STOPPING

Stopping a persistent runner is easy

    $ yath stop

=head3 INFORMATIONAL

The C<which> command will tell you which persistent runner will be used. Yath
sreaches for the persistent runner in the current directory, then searches in
parent directories until it either hits root, or finds the persistent runner
tracking file.

    $ yath which

The C<watch> command will tail the runners log files.

    $ yath watch

=head3 PRELOAD + PERSISTENT RUNNER

You can use preloads with the C<yath start> command. In this case yath will
track all the modules pulled in during preload, if any of them changes the
server will reload itself to bring in the changes. Further, modified modules
will be blacklisted so that they are not preloaded on the next reloads. This
behavior is useful if you are actively working on a module that is normally
preloaded.

=head2 MAKING YOUR PROJECT ALWAYS USE YATH

    $ yath init

The above command will create C<test.pl>. C<test.pl> is automatically run by
most build utils, in which case only the exit value matters. The generated
C<test.pl> will run C<yath> and excute all tests in the C<./t> and/or C<./t2>
directories. Tests in C<./t> will ALSO be run by prove, Tests in C<./t2> will
only be run by yath.

=head2 PROJECT SPECIFIC YATH CONFIG

You can write a C<.yath.rc> file. The file format is very simple, use
C<[COMMAND]> sections to start the configuration for a command. Under the
section you can provide any options normally allowed by the command. When
C<yath> is run inside your project it will use the config specified in the rc
file, unless overriden by command line options. Comments start with a
semi-colon.

Example .yath.rc:

    [test]
    -B ;Always write a log, compressed with BZip2

    [start]
    -PMoose ;Always preload Moose with a persistent runner

=head2 HARNESS DIRECTIVES INSIDE TESTS

C<yath> will recognise a number of directive comments placed near the top of
any test files. These directives should be placed after the SHBANG line, but
before any real code or comments. These may be placed AFTER C<use> and
C<require> statements.

=over 4

=item good example 1

    #!/usr/bin/perl
    # HARNESS-NO-FORK

    ...

=item good example 2

    #!/usr/bin/perl
    use strict;
    use warnings;

    # HARNESS-NO-FORK

    ...

=item bad example 1

    #!/usr/bin/perl

    # blah

    # HARNESS-NO-FORK

    ...

=item bad example 2

    #!/usr/bin/perl

    print "hi\n";

    # HARNESS-NO-FORK

    ...

=back

=head3 HARNESS-NO-PRELOAD

    #!/usr/bin/perl
    # HARNESS-NO-PRELOAD

Use this if your test will fail when modules are preloaded. This will tell yath
to start a new perl process to run the script instead of forking with preloaded
modules.

Currently this implies HARNESS-NO-FORK, but that may not always be the case.

=head3 HARNESS-NO-FORK

    #!/usr/bin/perl
    # HARNESS-NO-FORK

Use this if your test file cannot run in a forked process, but instead must be
run directly with a new perl process.

This implies HARNESS-NO-PRELOAD.

=head3 HARNESS-NO-STREAM

C<yath> usually uses the L<Test2::Formatter::Stream> formatter instead of TAP.
Some tests depend on using a TAP formatter. This option will make C<yath> use
L<Test2::Formatter::TAP> or L<Test::Builder::Formatter>.

=head3 HARNESS-NO-TIMEOUT

c<yath> will usually kill a test if no events occur within a timeout (default
60 seconds). You can add this directive to tests that are expected to trip the
timeout, but should be allowed to continue.

=head3 HARNESS-CATEGORY-LONG

This lets you tell C<yath> that the test file is long-running. This is
primarily used when concurrency is turned on in order to run longer tests
earlier, and concurrently with shorter ones. There is also a C<yath> option to
skip all long category tests.

This category is set automatically if HARNESS-NO-TIMEOUT is set.

=head3 HARNESS-CATEGORY-MEDIUM

This lets you tell C<yath> that the test is medium-length.

This category is set automatically if HARNESS-NO-FORK or HARNESS-NO-PRELOAD are
set.

=head3 HARNESS-CATEGORY-ISOLATION

This lets you tell C<yath> that the test cannot be run concurrently with other
tests. Yath will hold off and run these tests 1 at a time after all other
tests.

=head3 HARNESS-CATEGORY-GENERAL

This is the default category.

=head1 MODULE DOCS

This section documents the L<App::Yath> module itself.

=head2 SYNOPSIS

This is the entire C<yath> script, comments removed.

    #!/usr/bin/env perl
    use App::Yath(\@ARGV, \$App::Yath::RUN);
    exit($App::Yath::RUN->());

=head2 METHODS

=over 4

=item $class->import(\@argv, \$runref)

This will find, load, and process the command as found via C<@argv> processing.
It will set C<$runref> to a coderef that should be executed at runtime (IE not
in the C<BEGIN> block implied by C<use>.

Please note that statements after the import may never be reached. A source
filter may be used to rewrite the rest of the file to be the source of a
running test.

=item $class->info("Message")

Print a message to STDOUT.

=item $class->run_command($cmd_class, $cmd_name, \@argv)

Run a command identified by C<$cmd_class> and C<$cmd_name>, using C<\@argv> as
input.

=item $cmd_name = $class->parse_argv(\@argv)

Determine what command should be used based on C<\@argv>. C<\@argv> may be
modified depending on what it contains.

=item $cmd_class = $class->load_command($cmd_name)

Load a command by name, returns the class of the command.

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
