use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic encode_json/;

use App::Yath2::LogArchive;
use App::Yath2::Command::replay;

# Replay's run() now goes through App::Yath2::Options::Renderer::init_renderers
# which calls $settings->renderer / ->term / ->check_group. The test does
# not exercise renderer behavior, but the call has to succeed -- stub a
# minimal settings object that satisfies the shape init_renderers wants.
{
    package Fake::Renderer;
    sub new     { bless {}, $_[0] }
    sub theme   { 'App::Yath2::Theme::Default' }
    sub qvf     { 0 }
    sub verbose { 0 }
    sub quiet   { 0 }
    sub server  { undef }
    sub classes { {'App::Yath2::Renderer::Default' => []} }
    sub wrap    { 1 }
    sub all     { () }

    package Fake::Term;
    sub new   { bless {}, $_[0] }
    sub color { 0 }
    sub all   { () }

    package Fake::Settings;
    sub new {
        bless {
            renderer => Fake::Renderer->new,
            term     => Fake::Term->new,
        } => $_[0];
    }
    sub renderer    { $_[0]->{renderer} }
    sub term        { $_[0]->{term} }
    sub check_group { exists $_[0]->{$_[1]} ? 1 : 0 }
}

sub _new_replay {
    return App::Yath2::Command::replay->new(
        args     => [@_],
        settings => Fake::Settings->new,
    );
}

# Build a synthetic log directory with one passing and one failing
# run, pack it as a .yath archive, then drive the replay command
# and check its output + exit code.

my $tmp  = tempdir(CLEANUP => 1);
my $logs = "$tmp/logs";
make_path("$logs/runs/RP/tests/J");
make_path("$logs/runs/RF/tests/J");

for my $rid (qw/RP RF/) {
    my $pass = $rid eq 'RP' ? 1 : 0;

    # Phase 4 log layout: spec.json + state.json sit alongside the
    # event log under runs/<run_id>/. Consumers (LogArchive::artifacts)
    # reject any runs/<id>/ that lacks spec.json. The static streamer
    # picks up every *.json under runs/<id>/ as a state snapshot
    # (loggers are resolved by extension), so spec.json and state.json
    # must agree -- mirror the same content into both.
    my $state = {
        run_id  => $rid, created_at => 1, pending => [], running => [],
        done    => ['J'],
        results => {
            J => {
                queued_at => 1, started_at => 2, completed_at => 3,
                pass => $pass, exit => $pass ? 0 : 256,
                rel_file => 't/j.t', abs_file => '/abs/j.t', file => '/abs/j.t',
            },
        },
    };
    write_json_file_atomic("$logs/runs/$rid/spec.json",  $state);
    write_json_file_atomic("$logs/runs/$rid/state.json", $state);
    open my $jf, '>', "$logs/runs/$rid/tests/J/0.jsonl" or die $!;
    print $jf encode_json({event_id => "$rid-EV", facet_data => {info => [{details => $rid}]}}), "\n";
    close $jf;
}

my $archive = "$tmp/run.yath";
App::Yath2::LogArchive->open(dir => $logs)->archive($archive);
ok(-f $archive, 'archive created');

subtest 'replay directory, all runs -> exit 1 (one run failed)' => sub {
    my $cmd = _new_replay($logs);
    my $out = '';
    my $rc;
    {
        # Renderer clones STDOUT into its own handle at construction
        # (see App::Yath2::Renderer::Default::init), so a plain
        # `select` on a scalar handle does not capture renderer
        # output. Redirect the real STDOUT for the duration of the
        # call instead.
        open(my $orig_stdout, '>&', \*STDOUT) or die "dup stdout: $!";
        close STDOUT;
        open(STDOUT, '>', \$out) or die "open scalar stdout: $!";
        $rc = eval { $cmd->run };
        my $err = $@;
        close STDOUT;
        open(STDOUT, '>&', $orig_stdout) or die "restore stdout: $!";
        die $err if $err;
    }

    is($rc, 1, 'exit 1 because one replayed run failed');
    # Replay now drives events through the renderer chain rather than
    # emitting raw JSON, so the regression sentinels look at the
    # human-readable output. PASSED + FAILED markers prove both the
    # passing and failing runs reached the renderer; the RP / RF
    # info-event payloads appear in their own line.
    like($out, qr/PASSED/, 'passing run reached the renderer');
    like($out, qr/FAILED/, 'failing run reached the renderer');
    like($out, qr/\bRP\b/, 'RP general event passed through');
    like($out, qr/\bRF\b/, 'RF general event passed through');
};

subtest 'replay archive, filter to passing run -> exit 0' => sub {
    my $cmd = _new_replay($archive, 'RP');
    my $out = '';
    my $rc;
    {
        # Renderer clones STDOUT into its own handle at construction
        # (see App::Yath2::Renderer::Default::init), so a plain
        # `select` on a scalar handle does not capture renderer
        # output. Redirect the real STDOUT for the duration of the
        # call instead.
        open(my $orig_stdout, '>&', \*STDOUT) or die "dup stdout: $!";
        close STDOUT;
        open(STDOUT, '>', \$out) or die "open scalar stdout: $!";
        $rc = eval { $cmd->run };
        my $err = $@;
        close STDOUT;
        open(STDOUT, '>&', $orig_stdout) or die "restore stdout: $!";
        die $err if $err;
    }

    is($rc, 0, 'exit 0 when only the passing run is replayed');
    like($out,   qr/\bRP\b/, 'RP event present');
    unlike($out, qr/\bRF\b/, 'RF event NOT present (filtered out)');
};

subtest 'replay archive, filter to failing run -> exit 1' => sub {
    my $cmd = _new_replay($archive, 'RF');
    my $out = '';
    my $rc;
    {
        # Renderer clones STDOUT into its own handle at construction
        # (see App::Yath2::Renderer::Default::init), so a plain
        # `select` on a scalar handle does not capture renderer
        # output. Redirect the real STDOUT for the duration of the
        # call instead.
        open(my $orig_stdout, '>&', \*STDOUT) or die "dup stdout: $!";
        close STDOUT;
        open(STDOUT, '>', \$out) or die "open scalar stdout: $!";
        $rc = eval { $cmd->run };
        my $err = $@;
        close STDOUT;
        open(STDOUT, '>&', $orig_stdout) or die "restore stdout: $!";
        die $err if $err;
    }

    is($rc, 1, 'exit 1 when replayed run failed');
    like($out,   qr/\bRF\b/, 'RF event present');
    unlike($out, qr/\bRP\b/, 'RP event NOT present');
};

subtest 'missing log path is rejected' => sub {
    my $cmd = _new_replay("$tmp/nope.yath");
    my $ok  = eval { $cmd->run; 1 };
    my $err = $@;
    ok(!$ok, 'died');
    like($err, qr/does not exist/, 'error mentions missing log');
};

done_testing;
