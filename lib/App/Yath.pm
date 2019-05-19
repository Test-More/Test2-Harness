package App::Yath;
use strict;
use warnings;

use App::Yath::Util qw/read_config find_pfile/;
use File::Spec;
use Test2::Util qw/IS_WIN32/;

our $VERSION = '0.001076';

our $SCRIPT;

sub import {
    # Do not let anything mess with our $.
    local $.;

    my $class = shift;
    my ($argv, $runref) = @_ or return;

    my $old = select STDOUT;
    $| = 1;
    select STDERR;
    $| = 1;
    select $old;

    my ($pkg, $file, $line) = caller;

    $SCRIPT ||= $file;

    my $cmd_name = $class->command_from_argv($argv);
    my $pp_argv  = $class->pre_parse_args(
        [
            read_config($cmd_name, file => '.yath.rc',      search => 1),
            read_config($cmd_name, file => '.yath.user.rc', search => 1),
            @$argv
        ]
    );

    unless (IS_WIN32) {
        my %have = map {( $_ => 1, File::Spec->rel2abs($_) => 1 )} @INC;
        my @missing = grep { !$have{$_} && !$have{File::Spec->rel2abs($_)} } @{$pp_argv->{inc}};

        $class->do_exec($^X, (map {('-I' => File::Spec->rel2abs($_))} @{$pp_argv->{inc}}, @INC), $SCRIPT, $cmd_name, @$argv)
            if @missing;
    }

    my $cmd_class = $class->load_command($cmd_name);
    $cmd_class->import($argv, $runref);

    $$runref ||= sub { $class->run_command($cmd_class, $cmd_name, $pp_argv) };
}

sub do_exec {
    my $class = shift;
    exec(@_);
}

sub pre_parse_args {
    my $class = shift;
    my ($args) = @_;

    my (@opts, @list, @pass, @plugins, @inc);

    my %lib = (lib => 1, blib => 1, tlib => 0);

    my $last_mark = '';
    for my $arg (@$args) {
        if ($last_mark eq '::') {
            push @pass => $arg;
        }
        elsif ($last_mark eq '--') {
            if ($arg eq '::') {
                $last_mark = $arg;
                next;
            }
            push @list => $arg;
        }
        elsif ($last_mark eq 'plugin') {
            $last_mark = '';
            push @plugins => $arg;
        }
        elsif ($last_mark eq 'inc') {
            $last_mark = '';
            push @inc => $arg;
            push @opts => $arg;
        }
        else {
            if ($arg eq '--' || $arg eq '::') {
                $last_mark = $arg;
                next;
            }
            if ($arg eq '-p' || $arg eq '--plugin') {
                $last_mark = 'plugin';
                next;
            }
            if ($arg =~ m/^(?:-p=?|--plugin=)(.*)$/) {
                push @plugins => $1;
                next;
            }
            if ($arg eq '--no-plugins') {
                # clear plugins
                @plugins = ();
                next;
            }

            if ($arg eq '-I' || $arg eq '--include') {
                $last_mark = 'inc';
                # No 'next' here.
            }
            elsif ($arg =~ m/^(-I|--include)=(.*)$/) {
                push @inc => $2;
                # No 'next' here.
            }
            elsif($arg =~ m/^-I(.*)$/) {
                push @inc => $1;
            }
            elsif ($arg =~ m/^--(no-)?(lib|blib|tlib)$/) {
                $lib{$2} = $1 ? 0 : 1;
            }

            push @opts => $arg;
        }
    }

    push @inc => File::Spec->rel2abs('lib') if $lib{lib};
    if ($lib{blib}) {
        push @inc => File::Spec->rel2abs('blib/lib');
        push @inc => File::Spec->rel2abs('blib/arch');
    }
    push @inc => File::Spec->rel2abs('t/lib') if $lib{tlib};

    return {
        opts    => \@opts,
        list    => \@list,
        pass    => \@pass,
        plugins => \@plugins,
        inc     => \@inc,
    };
}

sub info {
    my $class = shift;
    print STDOUT @_;
}

sub run_command {
    my $class = shift;
    my ($cmd_class, $cmd_name, $argv) = @_;

    my $cmd = $cmd_class->new(args => $argv);

    require Time::HiRes;
    my $start = Time::HiRes::time();
    my $exit  = $cmd->run;

    die "Command '$cmd_name' did not return an exit value.\n"
        unless defined $exit;

    if ($cmd->show_bench && !$cmd->settings->{quiet}) {
        require Test2::Util::Times;
        my $end = time;
        my $bench = Test2::Util::Times::render_bench($start, $end, times);
        $class->info($bench, "\n\n");
    }

    return $exit;
}

sub command_from_argv {
    my $class = shift;
    my ($argv) = @_;

    if (@$argv) {
        my $arg = $argv->[0];

        if ($arg =~ m/^-*h(elp)?$/i) {
            shift @$argv;
            return 'help';
        }

        if ($arg =~ m/\.jsonl(\.bz2|\.gz)?$/) {
            $class->info("\n** First argument is a log file, defaulting to the 'replay' command **\n\n");
            return 'replay';
        }

        return shift @$argv if $class->load_command($arg, check_only => 1);

        my $is_opt_or_file = 0;
        $is_opt_or_file ||= -f $arg;
        $is_opt_or_file ||= -d $arg;
        $is_opt_or_file ||= $arg =~ m/^-/;

        # Assume it is a command, but an invalid one.
        return shift @$argv unless $is_opt_or_file;
    }

    if (find_pfile()) {
        $class->info("\n** Persistent runner detected, defaulting to the 'run' command **\n\n");
        return 'run';
    }

    $class->info("\n** Defaulting to the 'test' command **\n\n");
    return 'test';
}

sub load_command {
    my $class = shift;
    my ($cmd_name, %params) = @_;

    my $cmd_class  = "App::Yath::Command::$cmd_name";
    my $cmd_file   = "App/Yath/Command/$cmd_name.pm";

    my ($found, $error);
    {
        local $@;
        $found = eval { require $cmd_file; 1 };
        $error = $@;
    }

    if (!$found) {
        $error ||= 'unknown error';

        my $not_found = $error =~ m{Can't locate \Q$cmd_file\E in \@INC};

        return undef if $params{check_only} && $not_found;

        die "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)\n"
            if $not_found;

        die $error;
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

This document is mainly an overview of C<yath> usage and common recipes.

=head1 OVERVIEW

To use L<Test2::Harness>, you use the C<yath> command. Yath will find the tests
(or use the ones you specify) and run them. As it runs, it will output
diagnostic information such as failures. At the end, yath will print a summary
of the test run.

C<yath> can be thought of as a more powerful alternative to C<prove>
(L<Test::Harness>)

=head1 RECIPES

These are common recipes for using C<yath>.

=head2 RUN PROJECT TESTS

    $ yath

Simply running yath with no arguments means "Run all tests for the current
project". Yath will look for tests in C<./t>, C<./t2>, and C<./test.pl> and
run any which are found.

Normally this implies the C<test> command but will instead imply the C<run>
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
preload behavior is possible. See those docs for more info.

=head2 LOGGING

=head3 RECORDING A LOG

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

C<-B> and C<-G> both imply C<-L>.

=head3 REPLAYING FROM A LOG

You can replay a test run from a log file:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

This will be significantly faster than the initial run as no tests are actually
being executed. All events are simply read from the log, and processed by the
harness.

You can change display options and limit rendering/processing to specific test
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
useful when combined with preload.

=head3 STARTING

This starts the server. Many options available to the 'test' command will work
here but not all. See C<$ yath help start> for more info.

    $ yath start

=head3 RUNNING

This will run tests using the persistent runner. By default, it will search for
tests just like the 'test' command. Many options available to the C<test>
command will work for this as well. See C<$ yath help run> for more details.

    $ yath run

=head3 STOPPING

Stopping a persistent runner is easy.

    $ yath stop

=head3 INFORMATIONAL

The C<which> command will tell you which persistent runner will be used. Yath
searches for the persistent runner in the current directory, then searches in
parent directories until it either hits the root directory, or finds the
persistent runner tracking file.

    $ yath which

The C<watch> command will tail the runner's log files.

    $ yath watch

=head3 PRELOAD + PERSISTENT RUNNER

You can use preloads with the C<yath start> command. In this case, yath will
track all the modules pulled in during preload. If any of them change, the
server will reload itself to bring in the changes. Further, modified modules
will be blacklisted so that they are not preloaded on subsequent reloads. This
behavior is useful if you are actively working on a module that is normally
preloaded.

=head2 MAKING YOUR PROJECT ALWAYS USE YATH

    $ yath init

The above command will create C<test.pl>. C<test.pl> is automatically run by
most build utils, in which case only the exit value matters. The generated
C<test.pl> will run C<yath> and execute all tests in the C<./t> and/or C<./t2>
directories. Tests in C<./t> will ALSO be run by prove but tests in C<./t2>
will only be run by yath.

=head2 PROJECT-SPECIFIC YATH CONFIG

You can write a C<.yath.rc> file. The file format is very simple. Create a
C<[COMMAND]> section to start the configuration for a command and then
provide any options normally allowed by it. When C<yath> is run inside your
project, it will use the config specified in the rc file, unless overridden
by command line options.

Comments start with a semi-colon.

Example .yath.rc:

    [test]
    -B ;Always write a bzip2-compressed log

    [start]
    -PMoose ;Always preload Moose with a persistent runner

This file is normally committed into the project's repo.

=head2 PROJECT-SPECIFIC YATH CONFIG USER OVERRIDES

You can add a C<.yath.user.rc> file. Format is the same as the regular
C<.yath.rc> file. This file will be read in addition to the regular config
file. Directives in this file will come AFTER the directives in the primary
config so it may be used to override config.

This file should not normally be committed to the project repo.

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
