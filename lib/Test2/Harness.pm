package Test2::Harness;
use strict;
use warnings;

our $VERSION = '2.000005';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness - AKA 'yath' Yet Another Test Harness, A modern alternative to prove.

=head1 DESCRIPTION

This is the primary documentation for the C<yath> command, L<Test2::Harness>,
L<App::Yath> and all other related components.

The C<yath> command is an alternative to the C<prove> command and
L<Test::Harness>.

=head1 PLATFORM SUPPORT

L<Test2::Harness>/L<App::Yath> is is focused on unix-like platforms. Most
development happens on linux, but bsd, macos, etc should work fine as well.

Patches are welcome for any/all platforms, but the primary author (Chad
'Exodist' Granum) does not directly develop against non-unix platforms.

=head2 WINDOWS

Currently windows is not supported, and it is known that the package will not
install on windows. Patches are be welcome, and it would be great if someone
wanted to take on the windows-support role, but it is not a primary goal for
the project.

=head1 QUICK START

You can use C<yath> to run all the tests for your repo:

    $ yath test

Some important notes for those used to the C<prove> command:

=over 4

=item yath is recursive by default.

You do not need to add the C<-r> flag to reach tests in subdirectories of
C<t/> and C<t2/>.

=item The 'lib/', 'blib/lib', snd 'blib/arch' paths are added to your tests @INC for you.

No need to add '-Ilib', '-l', or '-b', as these are added automatically. They
can be disabled if desired, but in most cases you want them.

=item Yath will run tests concurrently by default

By default yath will run tests with multiple processes. If you have
L<System::Info> installed it will use half of your processors/cores, otherwise
it defaults to 2 processes.

Yoy can disable concurrency with the C<< -j1 >> flag, or specify a custom
concurrency value with C<< -j# >>.

=back

=head1 COMMAND LINE HELP

There are a couple useful things to be aware of:

=over 4

=item yath help - Get a list of commands

This will provide you with a list of available yath commands, and a brief
description of what they do.

=item yath COMMAND --help

=item yath help COMMAND

These are both effectively the same thing, they let you get command specific
help.

=item yath COMMAND --help=SECTION

Sometimes a command may have an overwhelming number of options. You can filter
it to specific sections to make it easier to find what you are looking for. At
the very end of the help dialogue is a list of sections to help you get start.

=item yath COMMAND [OPTIONS] --show-opts

=item yath COMMAND [OPTIONS] --show-opts=GROUP

This will show you what yath interpreted all your config and command line args
to mean in a tree view. This is useful if you suspect a command line flag is
not being handled properly.

=back

=head1 CONFIGURATION FILES

Yath will read from the following configuration files when you run it.

B<Note:> These should be located in your projects root directory, yath will
search parent directories to find them.

=over 4

=item .yath.rc

This should contain project specific flags you always want used regardless of
the machine. This file B<SHOULD> be commited to your project repository.

=item .yath.user.rc

This should contain user specific flags that you onyl want to apply when you
run tests. This file B<SHOULD NOT> be commited to yor project repository.

=back

The format of the config files is:

    # GLOBAL OPTIONS FOR ALL COMMANDS
    -D/path/to/my/spcial/libs

    [test]              # Options for the 'test' command
    -j32                # Always use 32 processes for concurrency
    -Irel(foo/bar)      # Always include this path relative to the location of the .rc file
    -Irel(foo/bar/*)    # Wildcard expanded to multiple -I.. options

    [start]
    ...

=over 4

=item Any option that is valid at the command line can be put into the .rc file.

=item Anything listed before a command section applies to all commands.

=item Anything after a C<[COMMAND]> section applies only to that command

=item rel(...) can be used to provide paths relative to the location of the .rc file.

=item rel(..*) wildcards will be expanded

=item # starts a comment

=back

=head1 PRELOADING AND CONCURRENCY FOR FASTER TEST RUNS

You can preload modules that are expensive to load, then yath will launch tests
from these preloaded states. In some cases this can provide a massive speedup:

    yath test -PMoose -PList::Util -PScalar::Util

In addition yath can run multiple concurrent jobs (specified with the C<-j#>
command line option.

    yath test -j16

You can combine these for a compounding performance boost:

    yath test -j16 -PMoose

=head2 BENCHMARKING WITH THE MOOSE TEST SUITE:

=over 4

=item No concurrency, no preload (85s):

    $ yath test -j1
    [...]
         File Count: 478
    Assertion Count: 19546
          Wall Time: 85.10 seconds
           CPU Time: 53.33 seconds (usr: 3.61s | sys: 0.17s | cusr: 44.85s | csys: 4.70s)
          CPU Usage: 62%

=item No concurrency, but preload (26s):

    $ yath test -j1 -PMoose
    [...]
         File Count: 478
    Assertion Count: 19545
          Wall Time: 26.84 seconds
           CPU Time: 18.39 seconds (usr: 2.71s | sys: 0.58s | cusr: 12.45s | csys: 2.65s)
          CPU Usage: 68%

=item Just concurrency, no preload (27s):

    $ yath test -j16
    [...]
         File Count: 478
    Assertion Count: 19546
          Wall Time: 27.25 seconds
           CPU Time: 58.62 seconds (usr: 4.24s | sys: 0.18s | cusr: 49.73s | csys: 4.47s)
          CPU Usage: 215%

=item Concurrency + Preload (7s):

    $ yath test -j16 -PMoose
    [...]
         File Count: 478
    Assertion Count: 19545
          Wall Time: 7.12 seconds
           CPU Time: 18.26 seconds (usr: 2.14s | sys: 0.10s | cusr: 13.93s | csys: 2.09s)
          CPU Usage: 256%

=back

As you can see concurrency and preloading make a huge difference in test run times!

See L</"ADVANCED CONCURRENCY"> and L</"ADVANCED PRELOADING"> for more information.

=head1 USING A WEB INTERFACE

B<Note:> It is better to create a standalone yath web server, rather than
creating a new instance for each run, Documentation on doing that will be
linked here when it is written.

    $ yath test --server

This will launch a web server (usually on L<http://127.0.0.1:8080>, but the url
will be printed for you at the start and end of the run) that allows you to
view the results and filter/inspect the output in full detail.

B<NOTE:> this requires installaction of one of the following sets of optional
modules:

=over 4

=item L<DBD::Pg> and L<DateTime::Format::Pg>

PostgreSQL, the database engine L<Test2::Harness> is primarily written against.

You can specify this one directly if you want to avoid database roulette:

    $ yath test --server=PostgreSQL

=item L<DBD::SQLite> and L<DateTime::Format::SQLite>

SQLite, the easiest option if you do not want to install a larger database engine.

You can specify this one directly if you want to avoid database roulette:

    $ yath test --server=SQLite

=item L<DBD::MariaDB>, L<DBD::mysql> and L<DateTime::Format::MySQL>

These modules will let you use direct MariaDB support instead of falling back
to a generic MySQL implementation.

    $ yath test --server=MariaDB

=item L<DBD::mysql> and L<DateTime::Format::MySQL>

With these modules installed you can choose to use generic MySQL, or a specific flavor of MySQL such as Percona.

You can specify this one directly if you want to avoid database roulette:

    $ yath test --server=MySQL
    $ yath test --server=Percona

B<Note:> Percona has no built-in UUID type, as such it will be slow to handle
operations that require UUIDs such as looking up specific events.

=back

=head2 HARNESS DIRECTIVES INSIDE TESTS

C<yath> will recognise a number of directive comments placed near the top of
test files. These directives should be placed after the C<#!> line but
before any real code.

Real code is defined as any line that does not start with use, require, BEGIN, package, or #

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

=head3 HARNESS-NO-IO-EVENTS

C<yath> can be configured to use the L<Test2::Plugin::IOEvents> plugin. This
plugin replaces STDERR and STDOUT in your test with tied handles that fire off
proper L<Test2::Event>'s when they are printed to. Most of the time this is not
an issue, but any fancy tests or modules which do anything with STDERR or
STDOUT other than print may have really messy errors.

B<Note:> This plugin is disabled by default, so you only need this directive if
you enable it globally but need to turn it back off for select tests.

=head3 HARNESS-NO-TIMEOUT

C<yath> will usually kill a test if no events occur within a timeout (default
60 seconds). You can add this directive to tests that are expected to trip the
timeout, but should be allowed to continue.

NOTE: you usually are doing the wrong thing if you need to set this. See:
C<HARNESS-TIMEOUT-EVENT>.

=head3 HARNESS-TIMEOUT-EVENT 60

C<yath> can be told to alter the default event timeout from 60 seconds to another
value. This is the recommended alternative to HARNESS-NO-TIMEOUT

=head3 HARNESS-TIMEOUT-POSTEXIT 15

C<yath> can be told to alter the default POSTEXIT timeout from 15 seconds to another value.

Sometimes a test will fork producing output in the child while the parent is
allowed to exit. In these cases we cannot rely on the original process exit to
tell us when a test is complete. In cases where we have an exit, and partial
output (assertions with no final plan, or a plan that has not been completed)
we wait for a timeout period to see if any additional events come into

=head3 HARNESS-DURATION-LONG

This lets you tell C<yath> that the test file is long-running. This is
primarily used when concurrency is turned on in order to run longer tests
earlier, and concurrently with shorter ones. There is also a C<yath> option to
skip all long tests.

This duration is set automatically if HARNESS-NO-TIMEOUT is set.

=head3 HARNESS-DURATION-MEDIUM

This lets you tell C<yath> that the test is medium.

This is the default duration.

=head3 HARNESS-DURATION-SHORT

This lets you tell C<yath> That the test is short.

=head3 HARNESS-CATEGORY-ISOLATION

This lets you tell C<yath> that the test cannot be run concurrently with other
tests. Yath will hold off and run these tests one at a time after all other
tests.

=head3 HARNESS-CATEGORY-IMMISCIBLE

This lets you tell C<yath> that the test cannot be run concurrently with other
tests of this class. This is helpful when you have multiple tests which would
otherwise have to be run sequentially at the end of the run.

Yath prioritizes running these tests above HARNESS-CATEGORY-LONG.

=head3 HARNESS-CATEGORY-GENERAL

This is the default category.

=head3 HARNESS-CONFLICTS-XXX

This lets you tell C<yath> that no other test of type XXX can be run at the
same time as this one. You are able to set multiple conflict types and C<yath>
will honor them.

XXX can be replaced with any type of your choosing.

NOTE: This directive does not alter the category of your test. You are free
to mark the test with LONG or MEDIUM in addition to this marker.

=head3 HARNESS-JOB-SLOTS 2

=head3 HARNESS-JOB-SLOTS 1 10

Specify a range of job slots needed for the test to run. If set to a single
value then the test will only run if it can have the specified number of slots.
If given a range the test will require at least the lower number of slots, and
use up to the maximum number of slots.

=over 4

=item Example with multiple lines.

    #!/usr/bin/perl
    # DASH and space are split the same way.
    # HARNESS-CONFLICTS-DAEMON
    # HARNESS-CONFLICTS  MYSQL

    ...

=item Or on a single line.

    #!/usr/bin/perl
    # HARNESS-CONFLICTS DAEMON MYSQL

    ...

=back

=head3 HARNESS-RETRY-n

This lets you specify a number (minimum n=1) of retries on test failure
for a specific test. HARNESS-RETRY-1 means a failing test will be run twice
and is equivalent to HARNESS-RETRY.

=head3 HARNESS-NO-RETRY

Use this to avoid this test being retried regardless of your retry settings.


=head1 ADVANCED CONCURRENCY

You can design your tests to use concurrency internally that is managed by yath!

You can sub-divide concurrency slots by specifying C<< -j#:# >>. This will set the
C<$ENV{T2_HARNESS_MY_JOB_CONCURRENCY}> env var to the number of concurrency
slots assigned to the test.

B<Note:> Tests are normally only assigned 1 concurrency slot unless they have
the C<# HARNESS-JOB-SLOTS MIN> or C<#HARNESS-JOB-SLOTS MIN MAX> headers at the
top of the file (they can be after the shbang or use statements, but must be
befor eany other code).

Here is an example of a test written to use anywhere from 1 to 5 slots
depending on how much yath gives it. Implementation of wait() and
start_child_process() is left to the reader.

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

=head1 ADVANCED PRELOADING

You can create custom preload classes (still loaded with C<-PClass>) that
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

Custom preload classes use the L<Test2::Harness::Preload> module to set up some
key meta-information, then you can define preload "stages".

A "stage" is a process with a preloaded state waiting for tests to run, when it
gets a test it will fork and the test will run in the fork. These stages/forks
are smart and use L<goto::file> to insure no stack frames or undesired state
contamination will be introduced into your test process.

Stages may be nested, that is you can build a parent stage, then have child
stages forked from that stage that inherit the state but also make independent
changes.

There are also several hooks available to inject behavior pre-fork, post-fork
and pre-launch.

=head2 FUNCTIONS AVAILABLE TO PRELOADS

=over 4

=item stage NAME => sub { ... }

=item stage("NAME", sub { ... })

Defines a stage, call hooks or other methods within the sub.

=item preload "Module::Name"

=item preload sub { ... }

This designates modules that should be loaded in any given stage. They will be
loaded in order. You may also provide a sub to do the loading if a simple
module name is not sufficient such as if you need localized env vars or other
clever tricks.

=item eager()

This designates a stage as eager. If a stage is eager then it will run tests
that usually ask for a nested/child stage. This is useful if a nested stage
takes a long time to load and you want tests that ask for it to start anyway
without waiting longer than they have to.

=item default()

This desginates a stage as the default one. This means it will be used if the
test does not request a specific stage. There can only be 1 default stage.

=item pre_fork sub { ... }

This sub will be called just before forking every time a test is forked off of
the stage. This is run in the parent process.

=item post_fork sub { ... }

This will be called immedietly after forking every time a test if forked off of
the stage. This is run in the child process.

=item pre_launch sub { ... }

This will be called in the child process after state has been manipulated just
before execution is handed off to the test file.

=back

=head2 SPECIFYING WHICH PRELOADS SHOULD BE USED FOR WHICH TESTS

The easiest way is to add a specific header comment to your test files:

    #!/usr/bin/perl
    use strict;
    use warnings
    # HARNESS-STAGE-MYSTAGE

You can also configure plugins (See L</"Plugins">) to assign tests to stages.

=head1 PLUGINS

TODO: WRITE ME!

=head1 RENDERERS

TODO: WRITE ME!

=head1 RESOURCES

TODO: WRITE ME!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT


