# NAME

App::Yath - Yet Another Test Harness (Test2-Harness) Command Line Interface
(CLI)

# DESCRIPTION

This is the primary documentation for `yath`, [App::Yath](https://metacpan.org/pod/App%3A%3AYath), [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness).

The canonical source of up-to-date command options are the help output when
using `$ yath help` and `$ yath help COMMAND`.

This document is mainly an overview of `yath` usage and common recipes.

[App::Yath](https://metacpan.org/pod/App%3A%3AYath) is an alternative to [App::Prove](https://metacpan.org/pod/App%3A%3AProve), and [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness) is an alternative to [Test::Harness](https://metacpan.org/pod/Test%3A%3AHarness). It is not designed to
replace [Test::Harness](https://metacpan.org/pod/Test%3A%3AHarness)/prove. [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness) is designed to take full
advantage of the rich data [Test2](https://metacpan.org/pod/Test2) can provide. [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness) is also able to
use non-core modules and provide more functionality than prove can achieve with
its restrictions.

# PLATFORM SUPPORT

[Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness)/[App::Yath](https://metacpan.org/pod/App%3A%3AYath) is is focused on unix-like platforms. Most
development happens on linux, but bsd, macos, etc should work fine as well.

Patches are welcome for any/all platforms, but the primary author (Chad
'Exodist' Granum) does not directly develop against non-unix platforms.

## WINDOWS

Currently windows is not supported, and it is known that the package will not
install on windows. Patches are be welcome, and it would be great if someone
wanted to take on the windows-support role, but it is not a primary goal for
the project.

# OVERVIEW

To use [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness), you use the `yath` command. Yath will find the tests
(or use the ones you specify) and run them. As it runs, it will output
diagnostic information such as failures. At the end, yath will print a summary
of the test run.

`yath` can be thought of as a more powerful alternative to `prove`
([Test::Harness](https://metacpan.org/pod/Test%3A%3AHarness))

# RECIPES

These are common recipes for using `yath`.

## RUN PROJECT TESTS

    $ yath

Simply running yath with no arguments means "Run all tests for the current
project". Yath will look for tests in `./t`, `./t2`, and `./test.pl` and
run any which are found.

Normally this implies the `test` command but will instead imply the `run`
command if a persistent test runner is detected.

## PRELOAD MODULES

Yath has the ability to preload modules. Yath normally forks to start new
tests, so preloading can reduce the time spent loading modules over and over in
each test.

Note that some tests may depend on certain modules not being loaded. In these
cases you can add the `# HARNESS-NO-PRELOAD` directive to the top of the test
files that cannot use preload.

### SIMPLE PRELOAD

Any module can be preloaded:

    $ yath -PMoose

You can preload as many modules as you want:

    $ yath -PList::Util -PScalar::Util

### COMPLEX PRELOAD

If your preload is a subclass of [Test2::Harness::Runner::Preload](https://metacpan.org/pod/Test2%3A%3AHarness%3A%3ARunner%3A%3APreload) then more
complex preload behavior is possible. See those docs for more info.

## LOGGING

### RECORDING A LOG

You can turn on logging with a flag. The filename of the log will be printed at
the end.

    $ yath -L
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl

The event log can be quite large. It can be compressed with bzip2.

    $ yath -B
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

gzip compression is also supported.

    $ yath -G
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.gz

`-B` and `-G` both imply `-L`.

### REPLAYING FROM A LOG

You can replay a test run from a log file:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

This will be significantly faster than the initial run as no tests are actually
being executed. All events are simply read from the log, and processed by the
harness.

You can change display options and limit rendering/processing to specific test
jobs from the run:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2 -v [TEST UUID(S)]

Note: This is done using the `$ yath replay ...` command. The `replay`
command is implied if the first argument is a log file.

## PER-TEST TIMING DATA

The `-T` option will cause each test file to report how long it took to run.

    $ yath -T

    ( PASSED )  job  1    t/yath_script.t
    (  TIME  )  job  1    Startup: 0.07692s | Events: 0.01170s | Cleanup: 0.00190s | Total: 0.09052s

## PERSISTENT RUNNER

yath supports starting a yath session that waits for tests to run. This is very
useful when combined with preload.

### STARTING

This starts the server. Many options available to the 'test' command will work
here but not all. See `$ yath help start` for more info.

    $ yath start

### RUNNING

This will run tests using the persistent runner. By default, it will search for
tests just like the 'test' command. Many options available to the `test`
command will work for this as well. See `$ yath help run` for more details.

    $ yath run

### STOPPING

Stopping a persistent runner is easy.

    $ yath stop

### INFORMATIONAL

The `which` command will tell you which persistent runner will be used. Yath
searches for the persistent runner in the current directory, then searches in
parent directories until it either hits the root directory, or finds the
persistent runner tracking file.

    $ yath which

The `watch` command will tail the runner's log files.

    $ yath watch

### PRELOAD + PERSISTENT RUNNER

You can use preloads with the `yath start` command. In this case, yath will
track all the modules pulled in during preload. If any of them change, the
server will reload itself to bring in the changes. Further, modified modules
will be blacklisted so that they are not preloaded on subsequent reloads. This
behavior is useful if you are actively working on a module that is normally
preloaded.

## MAKING YOUR PROJECT ALWAYS USE YATH

    $ yath init

The above command will create `test.pl`. `test.pl` is automatically run by
most build utils, in which case only the exit value matters. The generated
`test.pl` will run `yath` and execute all tests in the `./t` and/or `./t2`
directories. Tests in `./t` will ALSO be run by prove but tests in `./t2`
will only be run by yath.

## PROJECT-SPECIFIC YATH CONFIG

You can write a `.yath.rc` file. The file format is very simple. Create a
`[COMMAND]` section to start the configuration for a command and then
provide any options normally allowed by it. When `yath` is run inside your
project, it will use the config specified in the rc file, unless overridden
by command line options.

**Note:** You can also add pre-command options by placing them at the top of
your config file _BEFORE_ any `[cmd]` markers.

Comments start with a semi-colon.

Example .yath.rc:

    -pFoo ; Load the 'foo' plugin before dealing with commands.

    [test]
    -B ;Always write a bzip2-compressed log

    [start]
    -PMoose ;Always preload Moose with a persistent runner

This file is normally committed into the project's repo.

## PROJECT-SPECIFIC YATH CONFIG USER OVERRIDES

You can add a `.yath.user.rc` file. Format is the same as the regular
`.yath.rc` file. This file will be read in addition to the regular config
file. Directives in this file will come AFTER the directives in the primary
config so it may be used to override config.

This file should not normally be committed to the project repo.

## HARNESS DIRECTIVES INSIDE TESTS

`yath` will recognise a number of directive comments placed near the top of
test files. These directives should be placed after the `#!` line but
before any real code.

Real code is defined as any line that does not start with use, require, BEGIN, package, or #

- good example 1

        #!/usr/bin/perl
        # HARNESS-NO-FORK

        ...

- good example 2

        #!/usr/bin/perl
        use strict;
        use warnings;

        # HARNESS-NO-FORK

        ...

- bad example 1

        #!/usr/bin/perl

        # blah

        # HARNESS-NO-FORK

        ...

- bad example 2

        #!/usr/bin/perl

        print "hi\n";

        # HARNESS-NO-FORK

        ...

### HARNESS-NO-PRELOAD

    #!/usr/bin/perl
    # HARNESS-NO-PRELOAD

Use this if your test will fail when modules are preloaded. This will tell yath
to start a new perl process to run the script instead of forking with preloaded
modules.

Currently this implies HARNESS-NO-FORK, but that may not always be the case.

### HARNESS-NO-FORK

    #!/usr/bin/perl
    # HARNESS-NO-FORK

Use this if your test file cannot run in a forked process, but instead must be
run directly with a new perl process.

This implies HARNESS-NO-PRELOAD.

### HARNESS-NO-STREAM

`yath` usually uses the [Test2::Formatter::Stream](https://metacpan.org/pod/Test2%3A%3AFormatter%3A%3AStream) formatter instead of TAP.
Some tests depend on using a TAP formatter. This option will make `yath` use
[Test2::Formatter::TAP](https://metacpan.org/pod/Test2%3A%3AFormatter%3A%3ATAP) or [Test::Builder::Formatter](https://metacpan.org/pod/Test%3A%3ABuilder%3A%3AFormatter).

### HARNESS-NO-IO-EVENTS

`yath` usually uses the [Test2::Plugin::IOEvents](https://metacpan.org/pod/Test2%3A%3APlugin%3A%3AIOEvents) plugin. This plugin
replaces STDERR and STDOUT in your test with tied handles that fire off proper
[Test2::Event](https://metacpan.org/pod/Test2%3A%3AEvent)'s when they are printed to. Most of the time this is not an
issue, but any fancy tests or modules which do anything with STDERR or STDOUT
other than print may have really messy errors.

This directive will disable the plugin on a per-test basis. Alternatively you
can use the `--no-io-events` option when running yath to disable it globally
for your test suite.

### HARNESS-NO-TIMEOUT

`yath` will usually kill a test if no events occur within a timeout (default
60 seconds). You can add this directive to tests that are expected to trip the
timeout, but should be allowed to continue.

NOTE: you usually are doing the wrong thing if you need to set this. See:
`HARNESS-TIMEOUT-EVENT`.

### HARNESS-TIMEOUT-EVENT 60

`yath` can be told to alter the default event timeout from 60 seconds to another
value. This is the recommended alternative to HARNESS-NO-TIMEOUT

### HARNESS-TIMEOUT-POSTEXIT 15

`yath` can be told to alter the default POSTEXIT timeout from 15 seconds to another value.

Sometimes a test will fork producing output in the child while the parent is
allowed to exit. In these cases we cannot rely on the original process exit to
tell us when a test is complete. In cases where we have an exit, and partial
output (assertions with no final plan, or a plan that has not been completed)
we wait for a timeout period to see if any additional events come into

### HARNESS-DURATION-LONG

This lets you tell `yath` that the test file is long-running. This is
primarily used when concurrency is turned on in order to run longer tests
earlier, and concurrently with shorter ones. There is also a `yath` option to
skip all long tests.

This duration is set automatically if HARNESS-NO-TIMEOUT is set.

### HARNESS-DURATION-MEDIUM

This lets you tell `yath` that the test is medium.

This is the default duration.

### HARNESS-DURATION-SHORT

This lets you tell `yath` That the test is short.

### HARNESS-CATEGORY-ISOLATION

This lets you tell `yath` that the test cannot be run concurrently with other
tests. Yath will hold off and run these tests one at a time after all other
tests.

### HARNESS-CATEGORY-IMMISCIBLE

This lets you tell `yath` that the test cannot be run concurrently with other
tests of this class. This is helpful when you have multiple tests which would
otherwise have to be run sequentially at the end of the run.

Yath prioritizes running these tests above HARNESS-CATEGORY-LONG.

### HARNESS-CATEGORY-GENERAL

This is the default category.

### HARNESS-CONFLICTS-XXX

This lets you tell `yath` that no other test of type XXX can be run at the
same time as this one. You are able to set multiple conflict types and `yath`
will honor them.

XXX can be replaced with any type of your choosing.

NOTE: This directive does not alter the category of your test. You are free
to mark the test with LONG or MEDIUM in addition to this marker.

- Example with multiple lines.

        #!/usr/bin/perl
        # DASH and space are split the same way.
        # HARNESS-CONFLICTS-DAEMON
        # HARNESS-CONFLICTS  MYSQL

        ...

- Or on a single line.

        #!/usr/bin/perl
        # HARNESS-CONFLICTS DAEMON MYSQL

        ...

### HARNESS-RETRY-n

This lets you specify a number (minimum n=1) of retries on test failure
for a specific test. HARNESS-RETRY-1 means a failing test will be run twice
and is equivalent to HARNESS-RETRY.

### HARNESS-NO-RETRY

Use this to avoid this test being retried regardless of your retry settings.

# MODULE DOCS

This section documents the [App::Yath](https://metacpan.org/pod/App%3A%3AYath) module itself.

## SYNOPSIS

In practice you should never need to write your own yath script, or construct
an [App::Yath](https://metacpan.org/pod/App%3A%3AYath) instance, or even access themain instance when yath is running.
However some aspects of doing so are documented here for completeness.

A minimum yath script looks like this:

    BEGIN {
        package App::Yath:Script;

        require Time::HiRes;
        require App::Yath;
        require Test2::Harness::Settings;

        my $settings = Test2::Harness::Settings->new(
            harness => {
                orig_argv       => [@ARGV],
                orig_inc        => [@INC],
                script          => __FILE__,
                start           => Time::HiRes::time(),
                version         => $App::Yath::VERSION,
            },
        );

        my $app = App::Yath->new(
            argv    => \@ARGV,
            config  => {},
            settings => $settings,
        );

        $app->generate_run_sub('App::Yath::Script::run');
    }

    exit(App::Yath::Script::run());

It is important that most logic live in a BEGIN block. This is so that
[goto::file](https://metacpan.org/pod/goto%3A%3Afile) can be used post-fork to execute a test script.

The actual yath script is significantly more complicated with the following behaviors:

- pre-process essential arguments such as -D and no-scan-plugins
- re-exec with a different yath script if in developer mode and a local copy is found
- Parse the yath-rc config files
- gather and store essential startup information

## METHODS

App::Yath does not provide many methods to use externally.

- $app->generate\_run\_sub($symbol\_name)

    This tells App::Yath to generate a subroutine at the specified symbol name
    which can be run and be expected to return an exit value.

- $lib\_path = $app->app\_path()

    Get the include directory App::Yath was loaded from.

# SOURCE

The source code repository for Test2-Harness can be found at
`http://github.com/Test-More/Test2-Harness/`.

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright 2020 Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See `http://dev.perl.org/licenses/`
