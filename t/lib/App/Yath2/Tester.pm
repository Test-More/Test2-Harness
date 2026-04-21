package App::Yath2::Tester;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::API qw/context run_subtest/;
use Test2::Tools::Compare qw/is/;

use Carp qw/croak/;
use Config qw/%Config/;
use Cwd qw/getcwd/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;

use Test2::Harness2::Util        qw/apply_encoding clean_path/;
use Test2::Harness2::Util::IPC   qw/start_process swap_io/;
use Test2::Harness2::Util::File::JSONL;

use Importer Importer => 'import';
our @EXPORT    = qw/yath/;
our @EXPORT_OK = qw/yath find_yath make_example_dir/;

# A per-run persistence dir so stamp / lock files from one yath
# invocation don't leak into the next one.
my $pdir = tempdir(CLEANUP => 1);

# Locate the in-tree launcher (scripts/yath). Callers usually don't
# need to pass it explicitly -- the default walks up from the test
# file until it finds a scripts/yath sibling.
sub find_yath {
    my $here = getcwd();
    my $candidate = File::Spec->catfile($here, 'scripts', 'yath');
    return clean_path($candidate) if -f $candidate && -x $candidate;

    # Fall back to walking up a few levels; some test fixtures chdir
    # into a subtree before calling yath().
    my $dir = $here;
    for (1 .. 8) {
        my $up = File::Spec->catdir($dir, 'scripts', 'yath');
        return clean_path($up) if -f $up && -x $up;
        my $parent = File::Spec->catdir($dir, File::Spec->updir);
        last if clean_path($parent) eq clean_path($dir);
        $dir = $parent;
    }

    die "Could not find scripts/yath walking up from $here";
}

# The lib path for App::Yath2 -- we always add this as -I and -D so
# the nested yath process can load the same libraries we're testing.
sub _app_path {
    require App::Yath2;
    my $file = $INC{'App/Yath2.pm'} or die "App::Yath2 not loaded";
    my $path = clean_path($file);
    $path =~ s{/App/Yath2\.pm$}{};
    return $path;
}

sub yath {
    my %params = @_;

    my $ctx = context();

    my $cmd = delete $params{cmd} // delete $params{command};
    my $cli = delete $params{cli} // delete $params{args} // [];
    my $pre = delete $params{pre} // delete $params{pre_command} // [];
    my $env = delete $params{env} // {};
    my $enc = delete $params{encoding};

    my $timeout    = delete $params{timeout};
    my $timeout_cb = delete $params{timeout_cb};

    my $subtest  = delete $params{test} // delete $params{tests} // delete $params{subtest};
    my $exittest = delete $params{exit};

    my $debug   = delete $params{debug}   // 0;
    my $inc     = delete $params{inc}     // 1;
    my $capture = delete $params{capture} // 1;

    my $no_app_path = delete $params{no_app_path};
    my $lib         = delete $params{lib} // [];

    push @$lib => map { "-I$_" } grep { $_ ne '.' } @INC;

    croak "Unexpected parameters: " . join(', ', sort keys %params)
        if keys %params;

    # Adjacent-dev-lib bundle (if t/foo/bar.t has a t/foo/bar/lib dir,
    # add it as -I so the nested yath can load fixture modules).
    my @dev;
    if ($inc) {
        my (undef, $file) = caller();
        my $dir = $file;
        $dir =~ s/\.t2?$//g;

        my $bundle = File::Spec->catdir($dir, 'lib');
        push @dev => "-I$bundle" if -d $bundle;
    }

    my ($wh, $cfile);
    if ($capture) {
        ($wh, $cfile) = tempfile("yath-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.out');
        $wh->autoflush(1);
    }

    unless ($no_app_path) {
        my $apppath = _app_path();
        push @dev => "-I$apppath";
    }

    my $yath = find_yath();
    my @cmd = (
        $^X,
        @$lib,
        @dev,
        $yath,
        @$pre,
        defined($cmd) ? ($cmd) : (),
        @$cli,
    );

    print STDERR "DEBUG: Command = " . join(' ', @cmd) . "\n" if $debug;

    local %ENV = %ENV;
    $ENV{YATH_IPC_DIR}         = $pdir;
    $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    $ENV{YATH_CMD}             = $cmd if defined $cmd;
    $ENV{NESTED_YATH}          = 1;
    $ENV{T2_HARNESS_PROC_PREFIX}  = "nested";
    $ENV{T2_HARNESS2_PROC_PREFIX} = "nested";
    $ENV{YATH_SELF_TEST}       = 1;
    $ENV{YATH_COLOR}           = 0;
    $ENV{$_} = $env->{$_} for keys %$env;

    my $pid = start_process(
        \@cmd,
        sub {
            return unless $capture;
            swap_io(\*STDOUT, $wh);
            swap_io(\*STDERR, $wh);
        },
    );

    local $SIG{ALRM};
    if ($timeout) {
        $SIG{ALRM} = sub {
            $timeout_cb->($pid) if $timeout_cb;
            kill('TERM', $pid);
        };
        alarm($timeout);
    }

    my $our_pid = $$;
    eval "END { kill('TERM', \$pid) if \$pid && \$\$ == $our_pid }; 1" or die $@;

    close($wh) if $wh;

    print STDERR "DEBUG: Waiting for $pid\n" if $debug;
    waitpid($pid, 0);
    my $exit = $?;

    alarm(0) if $timeout;

    my @lines;
    if ($capture) {
        open(my $rh, '<', $cfile) or die "Could not open output file: $!";
        apply_encoding($rh, $enc) if $enc;
        @lines = <$rh>;
        close($rh);
        if ($debug > 1) {
            print STDERR map { chomp; "DEBUG: > $_\n" } @lines;
        }
    }

    $pid = undef;

    print STDERR "DEBUG: Exit: $exit\n" if $debug;

    my $out = {
        exit => $exit,
        ($capture ? (output => join('', @lines)) : ()),
    };

    my $name = join(
        ' ',
        map { length($_) < 30 ? $_ : substr($_, 0, 10) . "[...]" . substr($_, -10) }
            grep { defined($_) } 'yath',
        @$pre, defined($cmd) ? ($cmd) : (), @$cli
    );

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
            $ictx->diag(
                "Command = " . join(' ', grep { defined $_ } @cmd)
                    . "\nExit = $exit\n==== Output ====\n"
                    . ($out->{output} // '')
                    . "\n========"
            ) unless $ictx->hub->is_passing;
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

    open(my $fh, '>', $full) or die "open $full: $!";
    print $fh "use Test2::Tools::Tiny;\nok(1, 'a passing test');\ndone_testing\n";
    close($fh);

    return $full;
}

sub make_example_dir {
    my $dir = tempdir(CLEANUP => 1, TMP => 1);

    _gen_passing_test($dir, 't',  'test.t');
    _gen_passing_test($dir, 't2', 't2_test.t');
    _gen_passing_test($dir, 'xt', 'xt_test.t');

    return $dir;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Tester - Test support for running yath end-to-end from a test.

=head1 DESCRIPTION

Ported verbatim (with minor adaptations to the new tree) from
C<old/lib/App/Yath2/Tester.pm>. Lives under C<t/lib/> because it is
test-support, not a published API.

=head1 SYNOPSIS

    use App::Yath2::Tester qw/yath/;

    yath(
        command => 'test',
        args    => ['--ext=tx', 't/some/fixture'],
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/RESULT: PASSED/, 'run succeeded');
        },
    );

=head1 EXPORTS

=head2 $out = yath(%params)

Fork / exec the in-tree C<scripts/yath>, capture stdout+stderr, and
optionally run assertion callbacks against the captured output.

The result hashref has C<exit> (raw C<$?> from C<waitpid>) and
C<output> (captured as bytes; set C<encoding =E<gt> 'utf8'> to apply
a PerlIO layer before reading).

=head2 find_yath()

Return the absolute path to C<scripts/yath>, walking up from cwd.

=head2 make_example_dir()

Create a temporary directory populated with C<t/test.t>, C<t2/t2_test.t>,
C<xt/xt_test.t>, each trivially passing. Used by C<finder> /
C<projects> style tests.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
