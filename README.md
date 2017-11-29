# NAME

App::Yath - Yet Another Test Harness (Test2-Harness) Command Line Interface
(CLI)

# DESCRIPTION

**PLEASE NOTE:** Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

This is the primary documentation for `yath`, [App::Yath](https://metacpan.org/pod/App::Yath), [Test2::Harness](https://metacpan.org/pod/Test2::Harness).

The canonical source of up-to-date command options are the help output when
using `$ yath help` and `$ yath help COMMAND`.

This document is mainly for an overview of `yath` usage, and common recipes.

# OVERVIEW

To use [Test2::Harness](https://metacpan.org/pod/Test2::Harness) you use the `yath` command. Yath will find the tests
(or use the ones you specify), and run them. As it runs it will output
diagnostics information such as failures. At the end yath will print a summary
of the test run.

`yath` can be thought of as a more powerful alternative to `prove`
([Test::Harness](https://metacpan.org/pod/Test::Harness))

# RECIPES

These are common recipes for using `yath`.

## RUN PROJECT TESTS

    $ yath

Simply running yath with no arguments means "Run all tests for the current
project". Yath will look for tests in `./t`, `./t2`, and `./test.pl`,
running any that are found.

Normally this implies the `test` command, but will instead imply the `run`
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

If your preload is a subclass of [Test2::Harness::Preload](https://metacpan.org/pod/Test2::Harness::Preload) then more complex
preload behavior is possible. See the [Test2::Harness::Preload](https://metacpan.org/pod/Test2::Harness::Preload) docs for more
info.

## LOGGING

### RECORDING A LOG

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

`-B` and `-G` both imply `-L`.

### REPLAYING FROM A LOG

You can replay a test run from a log file:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

This will be significantly faster than the initial run as no tests are actually
being executed. All events are simply read from the log, and processed by the
harness.

You can change display options, and limit rendering/processing to specific test
jobs from the run:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2 -v 5 10

Note: This is done using the `$ yath replay ...` command. The `replay`
command is implied if the first argument is a log file.

## PER-TEST TIMING DATA

The `-T` option will cause each test file to report how long it took to run.

    $ yath -T

    ( PASSED )  job  1    t/App/Yath.t
    (  TIME  )  job  1    0.06942s on wallclock (0.07 usr 0.01 sys + 0.00 cusr 0.00 csys = 0.08 CPU)

## PERSISTENT RUNNER

yath supports starting a yath session that waits for tests to run. This is very
useful if combined with preload.

### STARTING

This starts the server, many options available to the 'test' command will work
here, but not all. See `$ yath help start` for more info.

    $ yath start

### RUNNING

This will run tests using the persistent runner. By default it will search for
tests just like the 'test' command. Many options available to the `test`
command will work for this as well. See `$ yath help run` for more details.

    $ yath run

### STOPPING

Stopping a persistent runner is easy

    $ yath stop

### INFORMATIONAL

The `which` command will tell you which persistent runner will be used. Yath
searches for the persistent runner in the current directory, then searches in
parent directories until it either hits root, or finds the persistent runner
tracking file.

    $ yath which

The `watch` command will tail the runners log files.

    $ yath watch

### PRELOAD + PERSISTENT RUNNER

You can use preloads with the `yath start` command. In this case yath will
track all the modules pulled in during preload, if any of them changes the
server will reload itself to bring in the changes. Further, modified modules
will be blacklisted so that they are not preloaded on the next reloads. This
behavior is useful if you are actively working on a module that is normally
preloaded.

## MAKING YOUR PROJECT ALWAYS USE YATH

    $ yath init

The above command will create `test.pl`. `test.pl` is automatically run by
most build utils, in which case only the exit value matters. The generated
`test.pl` will run `yath` and execute all tests in the `./t` and/or `./t2`
directories. Tests in `./t` will ALSO be run by prove, Tests in `./t2` will
only be run by yath.

## PROJECT SPECIFIC YATH CONFIG

You can write a `.yath.rc` file. The file format is very simple, use
`[COMMAND]` sections to start the configuration for a command. Under the
section you can provide any options normally allowed by the command. When
`yath` is run inside your project it will use the config specified in the rc
file, unless overridden by command line options. Comments start with a
semi-colon.

Example .yath.rc:

    [test]
    -B ;Always write a log, compressed with BZip2

    [start]
    -PMoose ;Always preload Moose with a persistent runner

This file is normally committed into the projects repo.

## USER PROJECT SPECIFIC YATH CONFIG

You can add a `.yath.user.rc` file. Format is the same as the regular
`.yath.rc` file. This file will be read in addition to the regular config
file. Directives in this file will come AFTER the directives in the primary
config, so it may be used to override config.

This file should not normally be committed to the project repo.

## HARNESS DIRECTIVES INSIDE TESTS

`yath` will recognise a number of directive comments placed near the top of
any test files. These directives should be placed after the SHBANG line, but
before any real code or comments. These may be placed AFTER `use` and
`require` statements.

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

`yath` usually uses the [Test2::Formatter::Stream](https://metacpan.org/pod/Test2::Formatter::Stream) formatter instead of TAP.
Some tests depend on using a TAP formatter. This option will make `yath` use
[Test2::Formatter::TAP](https://metacpan.org/pod/Test2::Formatter::TAP) or [Test::Builder::Formatter](https://metacpan.org/pod/Test::Builder::Formatter).

### HARNESS-NO-TIMEOUT

c&lt;yath> will usually kill a test if no events occur within a timeout (default
60 seconds). You can add this directive to tests that are expected to trip the
timeout, but should be allowed to continue.

### HARNESS-CATEGORY-LONG

This lets you tell `yath` that the test file is long-running. This is
primarily used when concurrency is turned on in order to run longer tests
earlier, and concurrently with shorter ones. There is also a `yath` option to
skip all long category tests.

This category is set automatically if HARNESS-NO-TIMEOUT is set.

### HARNESS-CATEGORY-MEDIUM

This lets you tell `yath` that the test is medium-length.

This category is set automatically if HARNESS-NO-FORK or HARNESS-NO-PRELOAD are
set.

### HARNESS-CATEGORY-ISOLATION

This lets you tell `yath` that the test cannot be run concurrently with other
tests. Yath will hold off and run these tests 1 at a time after all other
tests.

### HARNESS-CATEGORY-GENERAL

This is the default category.

# MODULE DOCS

This section documents the [App::Yath](https://metacpan.org/pod/App::Yath) module itself.

## SYNOPSIS

This is the entire `yath` script, comments removed.

    #!/usr/bin/env perl
    use App::Yath(\@ARGV, \$App::Yath::RUN);
    exit($App::Yath::RUN->());

## METHODS

- $class->import(\\@argv, \\$runref)

    This will find, load, and process the command as found via `@argv` processing.
    It will set `$runref` to a coderef that should be executed at runtime (IE not
    in the `BEGIN` block implied by `use`.

    Please note that statements after the import may never be reached. A source
    filter may be used to rewrite the rest of the file to be the source of a
    running test.

- $class->info("Message")

    Print a message to STDOUT.

- $class->run\_command($cmd\_class, $cmd\_name, \\@argv)

    Run a command identified by `$cmd_class` and `$cmd_name`, using `\@argv` as
    input.

- $cmd\_name = $class->parse\_argv(\\@argv)

    Determine what command should be used based on `\@argv`. `\@argv` may be
    modified depending on what it contains.

- $cmd\_class = $class->load\_command($cmd\_name)

    Load a command by name, returns the class of the command.

# SOURCE

The source code repository for Test2-Harness can be found at
`http://github.com/Test-More/Test2-Harness/`.

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright 2017 Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See `http://dev.perl.org/licenses/`
