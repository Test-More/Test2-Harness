package App::Yath::Tester;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::API qw/context/;
use App::Yath::Util qw/find_yath/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use POSIX;

use Test2::Harness::Util qw/clean_path/;

use Carp qw/croak/;

use Importer Importer => 'import';
our @EXPORT = qw/yath_test yath_test_with_log yath_start yath_stop yath_run yath_run_with_log yath/;

my $pdir = tempdir(CLEANUP => 1);

require App::Yath;
my $apppath = $INC{'App/Yath.pm'};
$apppath =~ s{App\S+Yath\.pm$}{}g;
$apppath = clean_path($apppath);

sub yath_test_with_log {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my ($exit, $out) = _yath('test', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile), $out);
}

sub yath_test {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('test', $file, $test, @options);
}

sub yath_start {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'start', @options);
}

sub yath_stop {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'stop', @options);
}

sub yath_run {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('run', $file, $test, @options);
}

sub yath_run_with_log {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my ($exit, $out) = _yath('run', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile), $out);
}


sub _yath {
    my ($cmd, $file, $test, @options) = @_;

    my $pre_opts = ref($options[0]) eq 'ARRAY' ? shift @options : [];

    my $dir = $file;
    $dir =~ s/\.t2?$//g;

    my $run = $test ? File::Spec->catfile($dir, "$test.tx") : undef;
    croak "Could not find test '$test' at '$run'" if $run && !-f $run;

    my $inc = File::Spec->catdir($dir, 'lib');
    $inc = undef unless -d $inc;

    my $yath = find_yath;

    pipe(my ($rh, $wh)) or die "Could not open pipe: $!";
    my @final = ($^X, $yath, $inc ? ("-D$inc") : (), '-D', @$pre_opts, $cmd, @options, $run ? ($run) : ());
    local $ENV{NESTED_YATH} = 1;
    my $pid = run_cmd(
        no_set_pgrp => 1,
        stderr => $wh,
        stdout => $wh,
        command => \@final,
    );

    close($wh);
    $rh->blocking(0);
    my (@lines, $exit);
    while(1) {
        push @lines => <$rh>;

        waitpid($pid, WNOHANG) or next;
        $exit = $?;
        last;
    }

    push @lines => <$rh>;

    return $exit unless wantarray;
    return ($exit, join '' => @lines);
}

sub yath {
    my %params = @_;

    my $ctx = context();

    my $cmd = $params{cmd} // $params{command};
    my $cli = $params{cli} // $params{args} // [];
    my $env = $params{env} // {};
    my $pre = $params{pre} // $params{pre_command} // [];

    $params{debug}   //= 0;
    $params{inc}     //= 1;
    $params{capture} //= 1;
    $params{log}     //= 0;

    my @inc;
    if ($params{inc}) {
        my ($pkg, $file) = caller();
        my $dir = $file;
        $dir =~ s/\.t2?$//g;

        my $inc = File::Spec->catdir($dir, 'lib');
        push @inc => "-D$inc" if -d $inc;
    }

    my ($rh, $wh);
    if ($params{capture}) {
        pipe($rh, $wh) or die "Could not open pipe: $!";
    }

    my (@log, $logfile);
    if ($params{log}) {
        my $fh;
        ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
        close($fh);
        @log = ('-F' => $logfile);
        print "DEBUG: log file = '$logfile'\n" if $params{debug};
    }

    unshift @inc => "-D$apppath";

    my $yath = find_yath;
    my @cmd = ($^X, $yath, @$pre, @inc, $cmd ? ($cmd) : (), @log, @$cli);

    print "DEBUG: Command = " . join(' ' => @cmd) . "\n" if $params{debug};

    local %ENV = %ENV;
    $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    $ENV{NESTED_YATH} = 1;
    $ENV{$_} = $env->{$_} for keys %$env;
    my $pid = run_cmd(
        no_set_pgrp => 1,
        $params{capture} ? (stderr => $wh, stdout => $wh) : (),
        command => \@cmd,
    );

    my (@lines, $exit);
    if ($params{capture}) {
        close($wh);

        $rh->blocking(0);
        while (1) {
            my @new = <$rh>;
            push @lines => @new;
            print map { chomp($_); "DEBUG: > $_\n" } @new if $params{debug} > 1;

            waitpid($pid, WNOHANG) or next;
            $exit = $?;
            last;
        }

        my @new = <$rh>;
        push @lines => @new;
        print map { chomp($_); "DEBUG: > $_\n" } @new if $params{debug} > 1;
    }
    else {
        print "DEBUG: Waiting for $pid\n" if $params{debug};
        waitpid($pid, 0);
        $exit = $?;
    }

    print "DEBUG: Exit: $exit\n" if $params{debug};

    $ctx->release;

    return {
        exit => $exit,
        $params{capture} ? (output => join('', @lines)) : (),
        $params{log} ? (log => Test2::Harness::Util::File::JSONL->new(name => $logfile)) : (),
    };
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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
