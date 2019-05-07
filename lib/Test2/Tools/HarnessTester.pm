package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '0.001075';

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util qw/open_file/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use List::Util qw/first/;
use File::Temp qw/tempdir/;
use File::Spec;

our @EXPORT_OK = qw/run_yath_command run_command make_example_dir yath_script summarize_events/;

my $YATH;

sub yath_script { $YATH }

sub import {
    my $class = shift;

    my @imports;
    my %params;
    while (@_) {
        my $arg = shift @_;
        if ($arg =~ m/^-(.*)/) {
            $params{$1} = shift @_;
        }
        else {
            push @imports => $arg;
        }
    }

    $YATH = File::Spec->rel2abs($params{yath_script}) if $params{yath_script};

    Importer->import_into($class, scalar(caller), @imports);
}

sub run_command {
    my (@cmd) = @_;

    pipe(my($r_out, $w_out)) or die "Could not open pipe for STDOUT: $!";
    pipe(my($r_err, $w_err)) or die "Could not open pipe for STDERR: $!";

    my $pid = run_cmd(stdout => $w_out, stderr => $w_err, command => \@cmd);
    close($w_out);
    close($w_err);

    my $ret = waitpid($pid, 0);
    my $exit = $?;

    die "Error waiting on child process" unless $ret == $pid;

    return {
        exit => $exit,
        stdout => join("" => <$r_out>),
        stderr => join("" => <$r_err>),
    };
}

sub run_yath_command {
    unless($YATH) {
        require App::Yath::Util;
        $YATH = File::Spec->rel2abs(App::Yath::Util::find_yath());
    }

    my @libs = map {( '-I' => File::Spec->rel2abs($_) )} @INC;
    return run_command($^X, @libs, $YATH, @_);
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

my $HARNESS_ID = 1;
sub summarize_events {
    my ($events) = @_;

    my @caller = caller(0);

    my $id     = $HARNESS_ID++;
    my $run_id = "run-$id";
    my $job_id = "job-$id";

    require Test2::Harness::Job;
    my $job = Test2::Harness::Job->new(
        file   => $caller[1],
        job_id => $job_id,
    );

    require Test2::Harness::Watcher;
    my $watcher = Test2::Harness::Watcher->new(job => $job, live => 0);

    require Test2::Harness::Event;
    for my $e (@$events) {
        my $fd = $e->facet_data;
        my $he = Test2::Harness::Event->new(
            facet_data => $fd,
            event_id   => gen_uuid(),
            run_id     => $run_id,
            job_id     => $job_id,
            stamp      => time,
        );

        $watcher->process($he);
    }

    $watcher->set_complete(1);

    return {
        plan       => $watcher->plan,
        pass       => $watcher->pass,
        fail       => $watcher->fail,
        errors     => $watcher->_errors,
        failures   => $watcher->_failures,
        assertions => $watcher->assertion_count,
    };
}

1;
