package Test2::Harness::Job::Runner::Dummy;
use strict;
use warnings;

our $VERSION = '0.001050';

use Test2::Harness::Util qw/open_file write_file local_env/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use Test2::Util qw/pkg_to_file/;

use File::Spec();

sub viable { 1 }

sub find_inc {
    my $class = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Job/Runner.pm"};
    $inc =~ s{/Test2/Harness/Job/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}

sub command {
    my $class = shift;
    my ($test, $event_file) = @_;

    my $job = $test->job;

    return (
        $^X,
        (map { "-I$_" } @{$job->libs}, $class->find_inc),
        $ENV{HARNESS_PERL_SWITCHES} ? $ENV{HARNESS_PERL_SWITCHES} : (),
        @{$job->switches},
        (map {"-m$_"} @{$job->load || []}),
        (map {"-M$_"} @{$job->load_import || []}),
        $job->use_stream ? ("-MTest2::Formatter::Stream=file,$event_file") : (),
        $job->times ? ('-MTest2::Plugin::Times') : (),
        '-e', 'print "1..0 # SKIP dummy mode"',
        @{$job->args},
    );
}

sub run {
    my $class = shift;
    my ($test) = @_;

    my $job = $test->job;

    my ($in_file, $out_file, $err_file, $event_file) = $test->output_filenames;

    my $out_fh = open_file($out_file, '>');
    my $err_fh = open_file($err_file, '>');

    write_file($in_file, $job->input);
    my $in_fh = open_file($in_file, '<');

    my $env = {
        %{$job->env_vars},
        $job->use_stream ? (T2_FORMATTER => 'Stream') : (),
    };

    my @cmd = $class->command($test, $event_file);

    my $pid;
    local_env $env => sub {
        $pid = run_cmd(
            command => \@cmd,
            stdin   => $in_fh,
            stdout  => $out_fh,
            stderr  => $err_fh,
        );
    };

    return ($pid, undef);
}

