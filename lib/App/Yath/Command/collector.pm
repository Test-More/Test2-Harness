package App::Yath::Command::collector;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Test2::Harness::Collector;
use Test2::Harness::IPC::Protocol;
use Test2::Harness::Collector::Auditor;
use Test2::Harness::Collector::IOParser::Stream;

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/start_process ipc_connect/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use Time::HiRes qw/time/;

use Getopt::Yath;
include_options('App::Yath::Options::Yath');

sub args_include_tests { 0 }

sub group { 'internal' }

sub summary  { "Run a test" }

warn "fixme";
sub description {
    return <<"    EOT";
    fixme
    EOT
}

my $warned = 0;
sub run {
    my $self = shift;
    my $settings = $self->settings;

    $0 = 'yath-collector';

    my ($json) = @{$self->{+ARGS}};
    my $data = decode_json($json);

    warn "Make run an object";
    my $run = $data->{run} or die "No run provided";

    my $job = $data->{job} or die "No job provided";
    my $jclass = $job->{job_class} // 'Test2::Harnes::Job';
    require(mod2file($jclass));
    $job = $jclass->new($job);

    my $inst_ipc_data = $run->{instance_ipc};
    my ($inst_ipc, $inst_con);
    my ($agg_ipc,  $agg_con)  = ipc_connect($run->{aggregator_ipc});

    my $handler;
    if ($inst_ipc_data) {
        if ($agg_con) {
            $handler = sub {
                for my $e (@_) {
                    $agg_con->send_message($e);

                    warn "Forward important events like timeout and bailout to instance" unless $warned++;
                    next;
                    ($inst_ipc, $inst_con) = ipc_connect($inst_ipc_data) unless $inst_con;
                }
            };
        }
        else {
            $handler = sub {
                for my $e (@_) {
                    print STDOUT encode_json($e), "\n";

                    warn "Forward important events like timeout and bailout to instance" unless $warned++;
                    next;
                    ($inst_ipc, $inst_con) = ipc_connect($inst_ipc_data) unless $inst_con;
                }
            };
        }
    }
    else {
        if ($agg_con) {
            $handler = sub { $agg_con->send_message($_) for @_ };
        }
        else {
            $handler = \*STDOUT;
        }
    }

    my $auditor = Test2::Harness::Collector::Auditor->new(%$job);
    my $parser  = Test2::Harness::Collector::IOParser::Stream->new(%$job, type => 'test');

    my $collector = Test2::Harness::Collector->new(
        %$job,
        parser  => $parser,
        auditor => $auditor,
        output  => $handler,
    );

    warn "FIXME";
    $ENV{T2_FORMATTER} = 'Stream';

    open(our $stderr, '>&', \*STDERR) or die "Could not clone STDERR";

    $SIG{__WARN__} = sub { print $stderr @_ };

    my $exit = 0;
    my $ok = eval {
        $collector->setup_child();

        my $pid = start_process($job->launch_command($run));

        $exit = $collector->process($pid);

        1;
    };
    my $err = $@;

    if (!$ok) {
        print $stderr $err;
        print STDERR "Test2 Harness Collector Error: $err";
        exit(255);
    }

    return $exit;
}

1;
__END__

    my $auditor = Test2::Harness::Collector::Auditor->new(run_id => 'FAKE', job_id => 'FAKE', job_try => 0, file => 't/fake.t');

    my $renderer = App::Yath::Renderer::Default->new;
    $renderer->start();

    my $collector = Test2::Harness::Collector->new(
        run_id => 'FAKE', job_id => 'FAKE', job_try => 0,
        parser  => Test2::Harness::Collector::IOParser::Stream->new(type => 'test', name => 't/fake.t', job_id => 'FAKE', run_id => 'FAKE', job_try => 0),
        auditor => $auditor,
        output  => sub { $renderer->render_event($_) for @_ },

