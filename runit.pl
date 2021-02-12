use strict;
use warnings;

use Carp::Always;
use Atomic::Pipe;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

my ($file) = @ARGV;

my ($stderr_r, $stderr_w);
pipe($stderr_r, $stderr_w) or die "$!";

my ($stdout_r, $stdout_w);
pipe($stdout_r, $stdout_w) or die "$!";

my ($stdin_r, $stdin_w);
pipe($stdin_r, $stdin_w) or die "$!";

my $job_id = '123';

my $pid = fork // die "$!";

if ($pid) {
    my $job = bless { retry => 0, file => $file }, 'AJOB';

    close($stdout_w);
    close($stderr_w);
    close($stdin_r);

    my $write = sub {
        for my $e (@_) {
            my $flags = $e->flags;
            my $json  = $e->as_json;
            #my $json = encode_pretty_json($e);

            my $fd = $e->facet_data;

            print "${flags}${json}\n";
        }

        return;
    };


    require Test2::Harness::Overseer;
    my $o = Test2::Harness::Overseer->new(
        job => $job,
        job_id => $job_id,
        job_try => 0,
        run_id => '111',
        child_pid => $pid,
        write => $write,
        input_pipes => {
            stdout => $stdout_r,
            stderr => $stderr_r,
        },

        output_pipe => $stdin_w,

        # Roughly 5mb of data
        output => join '' => (
            map {
                ("a" x 1024) . "\n",
                ("b" x 1024) . "\n",
                ("c" x 1024) . "\n",
                ("d" x 1024) . "\n",
                ("e" x 1024) . "\n",
            } 1 .. 1024
        )
    );

    $stdin_w = undef;

    $o->watch();
}
else {
    close($stdin_w);
    setpgrp(0, 0);
    no warnings 'once';
    require Test2::Formatter::Stream;
    open($main::REALOUT, '>&', STDOUT) or die "$!";
    open(STDOUT, '>&', $stdout_w) or die "$!";
    open(STDERR, '>&', $stderr_w) or die "$!";
    open(STDIN, '<&', $stdin_r) or die "$!";
    $ENV{T2_STREAM_JOB_ID} = $job_id;
    $ENV{T2_FORMATTER} = 'Stream';
    Test2::Formatter::Stream->import();
    do "./$file";
}

exit 0;

{
    package AJOB;

    sub retry { shift->{retry} }
    sub file  { shift->{file}  }
    sub rel_file { shift->{file} }
    sub abs_file { shift->{file} }

    sub TO_JSON { %{$_[0]} }
}

1;
