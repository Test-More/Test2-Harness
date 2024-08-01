# NAME

Test2::Harness - AKA 'yath' Yet Another Test Harness, A modern alternative to prove.

# DESCRIPTION

This is the primary documentation for the `yath` command, [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness),
[App::Yath](https://metacpan.org/pod/App%3A%3AYath) and all other related components.

The `yath` command is an alternative to the `prove` command and
[Test::Harness](https://metacpan.org/pod/Test%3A%3AHarness).

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

# QUICK START

You can use `yath` to run all the tests for your repo:

    $ yath test

Some important notes for those used to the `prove` command:

- yath is recursive by default.

    You do not need to add the `-r` flag to reach tests in subdirectories of
    `t/` and `t2/`.

- The 'lib/', 'blib/lib', snd 'blib/arch' paths are added to your tests @INC for you.

    No need to add '-Ilib', '-l', or '-b', as these are added automatically. They
    can be disabled if desired, but in most cases you want them.

- Yath will run tests concurrently by default

    By default yath will run tests with multiple processes. If you have
    [System::Info](https://metacpan.org/pod/System%3A%3AInfo) installed it will use half of your processors/cores, otherwise
    it defaults to 2 processes.

    Yoy can disable concurrency with the `-j1` flag, or specify a custom
    concurrency value with `-j#`.

# COMMAND LINE HELP

There are a couple useful things to be aware of:

- yath help - Get a list of commands

    This will provide you with a list of available yath commands, and a brief
    description of what they do.

- yath COMMAND --help
- yath help COMMAND

    These are both effectively the same thing, they let you get command specific
    help.

- yath COMMAND --help=SECTION

    Sometimes a command may have an overwhelming number of options. You can filter
    it to specific sections to make it easier to find what you are looking for. At
    the very end of the help dialogue is a list of sections to help you get start.

- yath COMMAND \[OPTIONS\] --show-opts
- yath COMMAND \[OPTIONS\] --show-opts=GROUP

    This will show you what yath interpreted all your config and command line args
    to mean in a tree view. This is useful if you suspect a command line flag is
    not being handled properly.

# CONFIGURATION FILES

Yath will read from the following configuration files when you run it.

**Note:** These should be located in your projects root directory, yath will
search parent directories to find them.

- .yath.rc

    This should contain project specific flags you always want used regardless of
    the machine. This file **SHOULD** be commited to your project repository.

- .yath.user.rc

    This should contain user specific flags that you onyl want to apply when you
    run tests. This file **SHOULD NOT** be commited to yor project repository.

The format of the config files is:

    # GLOBAL OPTIONS FOR ALL COMMANDS
    -D/path/to/my/spcial/libs

    [test]              # Options for the 'test' command
    -j32                # Always use 32 processes for concurrency
    -Irel(foo/bar)      # Always include this path relative to the location of the .rc file
    -Irel(foo/bar/*)    # Wildcard expanded to multiple -I.. options

    [start]
    ...

- Any option that is valid at the command line can be put into the .rc file.
- Anything listed before a command section applies to all commands.
- Anything after a `[COMMAND]` section applies only to that command
- rel(...) can be used to provide paths relative to the location of the .rc file.
- rel(..\*) wildcards will be expanded
- # starts a comment

# PRELOADING AND CONCURRENCY FOR FASTER TEST RUNS

You can preload modules that are expensive to load, then yath will launch tests
from these preloaded states. In some cases this can provide a massive speedup:

    yath test -PMoose -PList::Util -PScalar::Util

In addition yath can run multiple concurrent jobs (specified with the `-j#`
command line option.

    yath test -j16

You can combine these for a compounding performance boost:

    yath test -j16 -PMoose

## BENCHMARKING WITH THE MOOSE TEST SUITE:

- No concurrency, no preload (85s):

        $ yath test -j1
        [...]
             File Count: 478
        Assertion Count: 19546
              Wall Time: 85.10 seconds
               CPU Time: 53.33 seconds (usr: 3.61s | sys: 0.17s | cusr: 44.85s | csys: 4.70s)
              CPU Usage: 62%

- No concurrency, but preload (26s):

        $ yath test -j1 -PMoose
        [...]
             File Count: 478
        Assertion Count: 19545
              Wall Time: 26.84 seconds
               CPU Time: 18.39 seconds (usr: 2.71s | sys: 0.58s | cusr: 12.45s | csys: 2.65s)
              CPU Usage: 68%

- Just concurrency, no preload (27s):

        $ yath test -j16
        [...]
             File Count: 478
        Assertion Count: 19546
              Wall Time: 27.25 seconds
               CPU Time: 58.62 seconds (usr: 4.24s | sys: 0.18s | cusr: 49.73s | csys: 4.47s)
              CPU Usage: 215%

- Concurrency + Preload (7s):

        $ yath test -j16 -PMoose
        [...]
             File Count: 478
        Assertion Count: 19545
              Wall Time: 7.12 seconds
               CPU Time: 18.26 seconds (usr: 2.14s | sys: 0.10s | cusr: 13.93s | csys: 2.09s)
              CPU Usage: 256%

As you can see concurrency and preloading make a huge difference in test run times!

See ["ADVANCED CONCURRENCY"](#advanced-concurrency) and ["ADVANCED PRELOADING"](#advanced-preloading) for more information.

# USING A WEB INTERFACE

**Note:** It is better to create a standalone yath web server, rather than
creating a new instance for each run, Documentation on doing that will be
linked here when it is written.

    $ yath test --server

This will launch a web server (usually on [http://127.0.0.1:8080](http://127.0.0.1:8080), but the url
will be printed for you at the start and end of the run) that allows you to
view the results and filter/inspect the output in full detail.

**NOTE:** this requires installaction of one of the following sets of optional
modules:

- [DBD::Pg](https://metacpan.org/pod/DBD%3A%3APg) and [DateTime::Format::Pg](https://metacpan.org/pod/DateTime%3A%3AFormat%3A%3APg)

    PostgreSQL, the database engine [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness) is primarily written against.

    You can specify this one directly if you want to avoid database roulette:

        $ yath test --server=PostgreSQL

- [DBD::SQLite](https://metacpan.org/pod/DBD%3A%3ASQLite) and [DateTime::Format::SQLite](https://metacpan.org/pod/DateTime%3A%3AFormat%3A%3ASQLite)

    SQLite, the easiest option if you do not want to install a larger database engine.

    You can specify this one directly if you want to avoid database roulette:

        $ yath test --server=SQLite

- [DBD::MariaDB](https://metacpan.org/pod/DBD%3A%3AMariaDB), [DBD::mysql](https://metacpan.org/pod/DBD%3A%3Amysql) and [DateTime::Format::MySQL](https://metacpan.org/pod/DateTime%3A%3AFormat%3A%3AMySQL)

    These modules will let you use direct MariaDB support instead of falling back
    to a generic MySQL implementation.

        $ yath test --server=MariaDB

- [DBD::mysql](https://metacpan.org/pod/DBD%3A%3Amysql) and [DateTime::Format::MySQL](https://metacpan.org/pod/DateTime%3A%3AFormat%3A%3AMySQL)

    With these modules installed you can choose to use generic MySQL, or a specific flavor of MySQL such as Percona.

    You can specify this one directly if you want to avoid database roulette:

        $ yath test --server=MySQL
        $ yath test --server=Percona

    **Note:** Percona has no built-in UUID type, as such it will be slow to handle
    operations that require UUIDs such as looking up specific events.

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

`yath` can be configured to use the [Test2::Plugin::IOEvents](https://metacpan.org/pod/Test2%3A%3APlugin%3A%3AIOEvents) plugin. This
plugin replaces STDERR and STDOUT in your test with tied handles that fire off
proper [Test2::Event](https://metacpan.org/pod/Test2%3A%3AEvent)'s when they are printed to. Most of the time this is not
an issue, but any fancy tests or modules which do anything with STDERR or
STDOUT other than print may have really messy errors.

**Note:** This plugin is disabled by default, so you only need this directive if
you enable it globally but need to turn it back off for select tests.

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

### HARNESS-JOB-SLOTS 2

### HARNESS-JOB-SLOTS 1 10

Specify a range of job slots needed for the test to run. If set to a single
value then the test will only run if it can have the specified number of slots.
If given a range the test will require at least the lower number of slots, and
use up to the maximum number of slots.

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

# ADVANCED CONCURRENCY

You can design your tests to use concurrency internally that is managed by yath!

You can sub-divide concurrency slots by specifying `-j#:#`. This will set the
`$ENV{T2_HARNESS_MY_JOB_CONCURRENCY}` env var to the number of concurrency
slots assigned to the test.

**Note:** Tests are normally only assigned 1 concurrency slot unless they have
the `# HARNESS-JOB-SLOTS MIN` or `#HARNESS-JOB-SLOTS MIN MAX` headers at the
top of the file (they can be after the shbang or use statements, but must be
befor eany other code).

Here is an example of a test written to use anywhere from 1 to 5 slots
depending on how much yath gives it. Implementation of wait() and
start\_child\_process() is left to the reader.

    #!/usr/bin/perl
    use strict;
    use warnings;
    use Test2::V0;
    use Test2::IPC;
    # HARNESS-JOB-SLOTS 1 5

    my @kids;

    for my (1 .. $ENV{T2_HARNESS_MY_JOB_CONCURRENCY}) {
        push @kids => start_child_process(...);
    }

    wait($_) for @kids;

    done_testing;

# ADVANCED PRELOADING

You can create custom preload classes (still loaded with `-PClass`) that
define advanced preload behavior:

    package MyPreload;
    use strict;
    use warnings;

    # Using this class will turn this into an advanced preload class
    use Test2::Harness::Preload;

    stage ONLY_MOOSE => sub {
        preload 'Moose';
    };

    stage ORGANIZATION_COMMON_MODULES => sub {
        eager();
        default();

        preload 'Moose';
        preload 'My::Common::Foo';
        preload 'My::Common::Bar';

        preload sub { ... };

        stage APP_A => sub {
            preload 'My::App::A';

            post_fork sub { do_this_before_each_test_after_fork() };
        };

        stage APP_B => sub {
            preload 'My::APP::B;
        };
    };

    1;

Custom preload classes use the [Test2::Harness::Preload](https://metacpan.org/pod/Test2%3A%3AHarness%3A%3APreload) module to set up some
key meta-information, then you can define preload "stages".

A "stage" is a process with a preloaded state waiting for tests to run, when it
gets a test it will fork and the test will run in the fork. These stages/forks
are smart and use [goto::file](https://metacpan.org/pod/goto%3A%3Afile) to insure no stack frames or undesired state
contamination will be introduced into your test process.

Stages may be nested, that is you can build a parent stage, then have child
stages forked from that stage that inherit the state but also make independent
changes.

There are also several hooks available to inject behavior pre-fork, post-fork
and pre-launch.

## FUNCTIONS AVAILABLE TO PRELOADS

- stage NAME => sub { ... }
- stage("NAME", sub { ... })

    Defines a stage, call hooks or other methods within the sub.

- preload "Module::Name"
- preload sub { ... }

    This designates modules that should be loaded in any given stage. They will be
    loaded in order. You may also provide a sub to do the loading if a simple
    module name is not sufficient such as if you need localized env vars or other
    clever tricks.

- eager()

    This designates a stage as eager. If a stage is eager then it will run tests
    that usually ask for a nested/child stage. This is useful if a nested stage
    takes a long time to load and you want tests that ask for it to start anyway
    without waiting longer than they have to.

- default()

    This desginates a stage as the default one. This means it will be used if the
    test does not request a specific stage. There can only be 1 default stage.

- pre\_fork sub { ... }

    This sub will be called just before forking every time a test is forked off of
    the stage. This is run in the parent process.

- post\_fork sub { ... }

    This will be called immedietly after forking every time a test if forked off of
    the stage. This is run in the child process.

- pre\_launch sub { ... }

    This will be called in the child process after state has been manipulated just
    before execution is handed off to the test file.

## SPECIFYING WHICH PRELOADS SHOULD BE USED FOR WHICH TESTS

The easiest way is to add a specific header comment to your test files:

    #!/usr/bin/perl
    use strict;
    use warnings
    # HARNESS-STAGE-MYSTAGE

You can also configure plugins (See ["Plugins"](#plugins)) to assign tests to stages.

# PLUGINS

TODO: WRITE ME!

# RENDERERS

TODO: WRITE ME!

# RESOURCES

TODO: WRITE ME!

# SOURCE

The source code repository for Test2-Harness can be found at
[http://github.com/Test-More/Test2-Harness/](http://github.com/Test-More/Test2-Harness/).

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See [http://dev.perl.org/licenses/](http://dev.perl.org/licenses/)
