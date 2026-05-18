use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempfile/;
use App::Yath2::Renderer2::Base;
use App::Yath2::Renderer2::Loop;

# Helper to build a minimal renderer without a real log.
sub _renderer {
    App::Yath2::Renderer2::Base->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );
}

# --- undef endpoint: no-op, no warning, ipc not disabled ---
{
    my $r        = _renderer();
    my $warn_buf = '';
    local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
    $r->connect_ipc(undef);

    is($r->ipc_disabled, 0,  'undef endpoint: ipc not disabled');
    is($r->_has_ipc,     0,  'undef endpoint: no ipc handle');
    is($warn_buf,        '', 'undef endpoint: no warning');
}

# --- empty string endpoint: no-op, no warning, ipc not disabled ---
{
    my $r        = _renderer();
    my $warn_buf = '';
    local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
    $r->connect_ipc('');

    is($r->ipc_disabled, 0,  'empty endpoint: ipc not disabled');
    is($r->_has_ipc,     0,  'empty endpoint: no ipc handle');
    is($warn_buf,        '', 'empty endpoint: no warning');
}

# --- bad endpoint (file doesn't exist): warns, marks disabled ---
{
    my $r        = _renderer();
    my $warn_buf = '';
    local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
    $r->connect_ipc('/tmp/nonexistent-ipc-endpoint-yath2-renderer-xyz');

    like($warn_buf, qr/cannot connect/i, 'bad endpoint: warning emitted');
    is($r->ipc_disabled, 1, 'bad endpoint: marks ipc disabled');
    is($r->_has_ipc,     0, 'bad endpoint: no ipc handle');
}

# --- bad endpoint: JSON file with invalid content also marks disabled ---
{
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.json');
    print $fh 'not valid json {{{';
    close $fh;

    my $r        = _renderer();
    my $warn_buf = '';
    local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
    $r->connect_ipc($path);

    like($warn_buf, qr/cannot connect/i, 'bad JSON: warning emitted');
    is($r->ipc_disabled, 1, 'bad JSON: marks ipc disabled');
}

# --- once disabled, connect_ipc is a no-op ---
{
    my $r = _renderer();
    $r->mark_ipc_disabled;

    my $warn_buf = '';
    local $SIG{__WARN__} = sub { $warn_buf .= $_[0] };
    $r->connect_ipc('/tmp/nonexistent-file');

    is($warn_buf,    '', 'already-disabled: no warning on connect_ipc');
    is($r->_has_ipc, 0,  'already-disabled: still no ipc handle');
}

# --- _check_ipc_signal short-circuits when ipc_disabled ---
{
    my $r = _renderer();
    $r->mark_ipc_disabled;

    is(
        App::Yath2::Renderer2::Loop::_check_ipc_signal($r),
        0,
        '_check_ipc_signal: 0 when ipc_disabled',
    );
}

# --- _check_ipc_signal returns 0 when no ipc connected ---
{
    my $r = _renderer();

    is(
        App::Yath2::Renderer2::Loop::_check_ipc_signal($r),
        0,
        '_check_ipc_signal: 0 when not connected',
    );
}

# --- ipc_stop_signaled: sticky once _IPC_STOP_SEEN is set ---
{
    my $r = _renderer();

    # Inject a stub IPC handle and pre-set the stop-seen flag directly.
    # This exercises the sticky short-circuit without needing a live bus.
    $r->{App::Yath2::Renderer2::Base::_IPC_STOP_SEEN()} = 1;
    $r->{App::Yath2::Renderer2::Base::_IPC()}           = bless {}, 'TestStub';

    is($r->_has_ipc,          1, 'stub ipc: _has_ipc true');
    is($r->ipc_stop_signaled, 1, 'sticky: ipc_stop_signaled returns 1');

    is(
        App::Yath2::Renderer2::Loop::_check_ipc_signal($r),
        1,
        '_check_ipc_signal: 1 when stop seen',
    );
}

# --- ipc_stop_signaled: returns 0 when handle present but stop not seen ---
{
    my $r = _renderer();

    # Inject a stub that returns no messages from get_messages.
    {

        package TestStub::NoMsg;
        sub get_messages { return () }
    }
    $r->{App::Yath2::Renderer2::Base::_IPC()} = bless {}, 'TestStub::NoMsg';

    is($r->_has_ipc,          1, 'stub ipc no-msg: _has_ipc true');
    is($r->ipc_stop_signaled, 0, 'no message: ipc_stop_signaled returns 0');
    is($r->ipc_disabled,      0, 'no message: ipc_disabled unchanged');
}

# --- ipc_stop_signaled: flips to 1 when bus delivers renderer_stop ---
{
    my $r = _renderer();

    {

        package TestStub::StopMsg;

        sub get_messages {
            return bless {content => {kind => 'renderer_stop'}}, 'FakeMsg';
        }
    }
    {

        package FakeMsg;
        sub content { $_[0]->{content} }
    }
    $r->{App::Yath2::Renderer2::Base::_IPC()} = bless {}, 'TestStub::StopMsg';

    is($r->ipc_stop_signaled, 1, 'renderer_stop: ipc_stop_signaled flips to 1');
    is(
        App::Yath2::Renderer2::Loop::_check_ipc_signal($r),
        1,
        '_check_ipc_signal: 1 after renderer_stop delivered',
    );
}

done_testing;
