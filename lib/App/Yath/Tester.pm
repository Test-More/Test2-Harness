package App::Yath::Tester;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::API qw/context run_subtest/;
use Test2::Tools::Compare qw/is/;

use Carp qw/croak/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;
use POSIX;
use Fcntl qw/SEEK_CUR/;

use App::Yath::Util qw/find_yath/;
use Test2::Harness::Util qw/clean_path apply_encoding/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use Test2::Harness::Util::File::JSONL;

use Importer Importer => 'import';
our @EXPORT = qw/yath make_example_dir/;

my $pdir = tempdir(CLEANUP => 1);

require App::Yath;
my $apppath = App::Yath->app_path;

sub cover {
    return unless $ENV{T2_DEVEL_COVER};
    $ENV{T2_COVER_SELF} = 1;
    return '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
}

sub yath {
    my %params = @_;

    my $ctx = context();

    my $cmd = delete $params{cmd} // delete $params{command};
    my $cli = delete $params{cli} // delete $params{args} // [];
    my $pre = delete $params{pre} // delete $params{pre_command} // [];
    my $env = delete $params{env} // {};
    my $enc = delete $params{encoding};
    my $prefix = delete $params{prefix};

    my $subtest  = delete $params{test} // delete $params{tests} // delete $params{subtest};
    my $exittest = delete $params{exit};

    my $debug   = delete $params{debug}   // 0;
    my $inc     = delete $params{inc}     // 1;
    my $capture = delete $params{capture} // 1;
    my $log     = delete $params{log}     // 0;

    my $no_app_path = delete $params{no_app_path};
    my $lib = delete $params{lib} // [];

    if (keys %params) {
        croak "Unexpected parameters: " . join (', ', sort keys %params);
    }

    my (@inc, @dev);
    if ($inc) {
        my ($pkg, $file) = caller();
        my $dir = $file;
        $dir =~ s/\.t2?$//g;

        my $inc = File::Spec->catdir($dir, 'lib');
        push @dev => "-D$inc" if -d $inc;
    }

    my ($wh, $cfile);
    if ($capture) {
        ($wh, $cfile) = tempfile("yath-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.out');
        $wh->autoflush(1);
    }

    my (@log, $logfile);
    if ($log) {
        my $fh;
        ($fh, $logfile) = tempfile("yathlog-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.jsonl');
        close($fh);
        @log = ('-F' => $logfile);
        print "DEBUG: log file = '$logfile'\n" if $debug;
    }

    unless ($no_app_path) {
        push @inc => "-I$apppath" if $cmd =~ m/^(test|start|projects)$/;
        push @dev => "-D$apppath";
    }

    my @cover = cover();

    my $yath = find_yath;
    my @cmd = ($^X, @$lib, @cover, $yath, @$pre, @dev, $cmd ? ($cmd) : (), @inc, @log, @$cli);

    print "DEBUG: Command = " . join(' ' => @cmd) . "\n" if $debug;

    local %ENV = %ENV;
    $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    $ENV{YATH_CMD} = $cmd;
    $ENV{NESTED_YATH} = 1;
    $ENV{'YATH_SELF_TEST'} = 1;
    $ENV{$_} = $env->{$_} for keys %$env;
    my $pid = run_cmd(
        no_set_pgrp => 1,
        $capture ? (stderr => $wh, stdout => $wh) : (),
        command => \@cmd,
        run_in_parent => [sub { close($wh) }],
    );

    my (@lines, $exit);
    if ($capture) {
        open(my $rh, '<', $cfile) or die "Could not open output file: $!";
        apply_encoding($rh, $enc) if $enc;
        $rh->blocking(0);
        while (1) {
            seek($rh, 0, SEEK_CUR); # CLEAR EOF
            my @new = <$rh>;
            push @lines => @new;
            print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;

            waitpid($pid, WNOHANG) or next;
            $exit = $?;
            last;
        }

        while (my @new = <$rh>) {
            push @lines => @new;
            print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;
        }
    }
    else {
        print "DEBUG: Waiting for $pid\n" if $debug;
        waitpid($pid, 0);
        $exit = $?;
    }

    print "DEBUG: Exit: $exit\n" if $debug;

    my $out = {
        exit => $exit,
        $capture ? (output => join('', @lines)) : (),
        $log ? (log => Test2::Harness::Util::File::JSONL->new(name => $logfile)) : (),
    };

    my $name = join(' ', map { length($_) < 30 ? $_ : substr($_, 0, 10) . "[...]" . substr($_, -10) } grep { defined($_) } $prefix, 'yath', @$pre, $cmd ? ($cmd) : (), @$cli);
    run_subtest(
        $name,
        sub {
            if (defined $exittest) {
                my $ictx = context(level => 3);
                is($exit, $exittest, "Exit Value Check");
                $ictx->release;
            }

            if ($subtest) {
                local $_ = $out->{output};
                local $? = $out->{exit};
                $subtest->($out);
            }

            my $ictx = context(level => 3);

            $ictx->diag("Command = " . join(' ' => grep { defined $_ } @cmd) . "\nExit = $exit\n==== Output ====\n$out->{output}\n========")
                unless $ictx->hub->is_passing;

            $ictx->release;
        },
        {buffered => 1},
        $out,
    ) if $subtest || defined $exittest;

    $ctx->release;

    return $out;
}

sub _gen_passing_test {
    my ($dir, $subdir, $file) = @_;

    my $path = File::Spec->catdir($dir, $subdir);
    my $full = File::Spec->catfile($path, $file);

    mkdir($path) or die "Could not make $subdir subdir: $!"
        unless -d $path;

    open(my $fh, '>', $full);
    print $fh "use Test2::Tools::Tiny;\nok(1, 'a passing test');\ndone_testing\n";
    close($fh);

    return $full;
}

sub make_example_dir {
    my $dir = tempdir(CLEANUP => 1, TMP => 1);

    _gen_passing_test($dir, 't', 'test.t');
    _gen_passing_test($dir, 't2', 't2_test.t');
    _gen_passing_test($dir, 'xt', 'xt_test.t');

    return $dir;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Tester - Tools for testing yath

=head1 DESCRIPTION

This package provides utilities for running yath from within tests to verify
its behavior. This is primarily used for integration testing of yath and for
third party components.

=head1 SYNOPSIS

    use App::Yath::Tester qw/yath/;

    my $result = yath(
        # Command and arguments
        command => 'test',
        args    => ['-pMyPlugin', 'path/to/test', ...],

        # Exit code we expect from yath
        exit => 0,

        # Subtest to verify results
        test => sub {
            my $result = shift;

            # Redundant since we have the exit check above
            is($result->{exit}, 0, "Verify exit");

            is($result->{output}, $expected_output, "Got the expected output from yath");
        },
    );

=head1 EXPORTS

There are 2 exports from this module.

=head2 $result = yath(...)

    my $result = yath(
        # Command and arguments
        command => 'test',
        args    => ['-pMyPlugin', 'path/to/test', ...],

        # Exit code we expect from yath
        exit => 0,

        # Subtest to verify results
        test => sub {
            my $result = shift;

            # Redundant since we have the exit check above
            is($result->{exit}, 0, "Verify exit");

            is($result->{output}, $expected_output, "Got the expected output from yath");
        },
    );

=head3 ARGUMENTS

=over 4

=item cmd => $command

=item command => $command

Either 'cmd' or 'command' can be used. This argument takes a string that should
be a command name.

=item cli => \@ARGS

=item args => \@ARGS

Either 'cli' or 'args' can be used. If none are provided an empty arrayref is
used. This argument takes an arrayref of arguments to the yath command.

    $ yath [PRE_COMMAND] [COMMAND] [ARGS]

=item pre => \@ARGS

=item pre_command => \@ARGS

Either 'pre' or 'pre_command' can be used. An empty arrayref is used if none
are provided. These are arguments provided to yath BEFORE the command on the
command line.

    $ yath [PRE_COMMAND] [COMMAND] [ARGS]

=item env => \%ENV

Provide custom environment variable values to set before running the yath
command.

=item encoding => $encoding_name

If you expect your yath command's output to be in a specific encoding you can
specify it here to make sure the C<< $result->{output} >> text has been read
properly.

=item test => sub { ... }

=item tests => sub { ... }

=item subtest => sub { ... }

These 3 arguments are all aliases for the same thing, only one should be used.
The codeblock will be called with C<$result> as the onyl argument. The
codeblock will be run as a subtest. If you specify the C<'exit'> argument that
check will also happen in the same subtest.

    test => sub {
        my $result = shift;

        ... verify result ...
    },

=item exit => $integer

Verify that the yath command exited with the specified exit code. This check
will be run in a subtest. If you specify a custom subtest then this check will
appear to come from that subtest.

=item debug => $integer

Output debug info in realtime, depending on the $integer value this may include
the output from the yath command being run.

    0 - No debugging
    1 - Output the command and other action being taken by the tool
    2 - Echo yath output as it happens

=item inc => $bool

This defaults to true.

When true the tool will look for a directory next to your test file with an
identical name except that '.t' or '.t2' will be stripped from it. If that
directory exists it will be added as a dev-lib to the yath command.

If your test file is 't/foo/bar.t' then your yath command will look like this:

    $ yath -D=t/foo/bar [PRE-COMMAND] [COMMAND] [ARGS]

=item capture => $bool

Defaults to true.

When true the yath output will be captured and put into
C<< $result->{output} >>.

=item log => $bool

Defaults to false.

When true yath will be instructed to produce a log, the log will be accessible
via C<< $result->{log} >>. C<< $result->{log} >> will be an instance of
L<Test2::Harness::Util::File::JSONL>.

=item no_app_path => $bool

Default to false.

Normally C<< -D=/path/to/lib >> is added to the yath command where
C<'/path/to/lib'> is the path the the lib dir L<App::Yath> was loaded from.
This normally insures the correct version of yath libraries is loaded.

When this argument is set to true the path is not added.

=item lib => [...]

This poorly named argument allows you to inject command line argumentes between
C<perl> and C<yath> in the command.

    perl [LIB] path/to/yath [PRE-COMMAND] [COMMAND] [ARGS]

=back

=head3 RESULT

The result hashref may containt he following fields depending on the arguments
passed into C<yath()>.

=over 4

=item exit => $integer

Exit value returned from yath.

=item output => $string

The output produced by the yath command.

=item log => $jsonl_object

An instance of L<Test2::Harness::Util::File::JSONL> opened from the log file
produced by the yath command.

B<Note:> By default no logging is done, you must specify the C<< log => 1 >>
argument to enable it.

=back

=head2 $path = make_example_dir()

This will create a temporary directory with 't', 't2', and 'xt' subdirectories
each of which will contain a single passing test.

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
