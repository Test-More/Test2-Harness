package App::Yath::Tester;
use strict;
use warnings;

our $VERSION = '1.000000';

use Test2::API qw/context run_subtest/;
use Test2::Tools::Compare qw/is/;

use Carp qw/croak/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;
use POSIX;

use App::Yath::Util qw/find_yath/;
use Test2::Harness::Util qw/clean_path apply_encoding/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use Test2::Harness::Util::File::JSONL;

use Importer Importer => 'import';
our @EXPORT = qw/yath make_example_dir/;

my $pdir = tempdir(CLEANUP => 1);

require App::Yath;
my $apppath = $INC{'App/Yath.pm'};
$apppath =~ s{App\S+Yath\.pm$}{}g;
$apppath = clean_path($apppath);

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

    my $subtest  = delete $params{test} // delete $params{tests} // delete $params{subtest};
    my $exittest = delete $params{exit};

    my $debug   = delete $params{debug}   // 0;
    my $inc     = delete $params{inc}     // 1;
    my $capture = delete $params{capture} // 1;
    my $log     = delete $params{log}     // 0;

    if (keys %params) {
        croak "Unexpected parameters: " . join (', ', sort keys %params);
    }

    my @inc;
    if ($inc) {
        my ($pkg, $file) = caller();
        my $dir = $file;
        $dir =~ s/\.t2?$//g;

        my $inc = File::Spec->catdir($dir, 'lib');
        push @inc => "-D$inc" if -d $inc;
    }

    my ($rh, $wh);
    if ($capture) {
        pipe($rh, $wh) or die "Could not open pipe: $!";
    }

    my (@log, $logfile);
    if ($log) {
        my $fh;
        ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
        close($fh);
        @log = ('-F' => $logfile);
        print "DEBUG: log file = '$logfile'\n" if $debug;
    }

    unshift @inc => "-D$apppath";

    my @cover = cover();

    my $yath = find_yath;
    my @cmd = ($^X, @cover, $yath, @$pre, @inc, $cmd ? ($cmd) : (), @log, @$cli);

    print "DEBUG: Command = " . join(' ' => @cmd) . "\n" if $debug;

    local %ENV = %ENV;
    $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    $ENV{YATH_CMD} = $cmd;
    $ENV{NESTED_YATH} = 1;
    $ENV{$_} = $env->{$_} for keys %$env;
    my $pid = run_cmd(
        no_set_pgrp => 1,
        $capture ? (stderr => $wh, stdout => $wh) : (),
        command => \@cmd,
    );

    my (@lines, $exit);
    if ($capture) {
        close($wh);

        apply_encoding($rh, $enc) if $enc;

        $rh->blocking(0);
        while (1) {
            my @new = <$rh>;
            push @lines => @new;
            print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;

            waitpid($pid, WNOHANG) or next;
            $exit = $?;
            last;
        }

        my @new = <$rh>;
        push @lines => @new;
        print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;
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

    my $name = join(' ', map { length($_) < 30 ? $_ : substr($_, 0, 10) . "[...]" . substr($_, -10) } 'yath', grep { defined($_) } @$pre, $cmd ? ($cmd) : (), @$cli);
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
