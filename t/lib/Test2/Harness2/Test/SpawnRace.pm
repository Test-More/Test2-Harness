package Test2::Harness2::Test::SpawnRace;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';
use Test2::Tools::Basic qw/todo fail/;

our @EXPORT_OK = qw/finish_and_wait/;

# Shapes of "the harness peer is gone" surfaced by
# IPC::Manager::Service::Handle::sync_request:
#   - "peer 'X' went away while awaiting response ..." -- the service
#     closed its channel while a request was in-flight.
#   - "'X' is not a valid message recipient ..." -- the client
#     registry no longer knows the peer name; the service already
#     tore down before this call.
# Both are legitimate end-of-life races around finish()/terminate();
# other errors must still propagate.
our $SERVICE_GONE = qr/peer .* went away|is not a valid message recipient/;

# Request a clean drain-and-exit from $spawn, then reap the service.
#
# finish() sends a drain-and-exit request and reads the ACK back on
# the same IPC channel; when the queue is already drained the service
# can exit before flushing the ACK, tripping one of the $SERVICE_GONE
# error shapes. We do not swallow that race silently: record a
# visible "not ok ... # TODO" assertion so the event stays audible in
# TAP while the caller still proceeds. Any other error propagates --
# the helper is not a general exception sink.
#
# Tracking:
#   https://github.com/Test-More/Test2-Harness/issues/391
# Long-term source-side fix (so this helper can go away):
#   https://github.com/Test-More/Test2-Harness/issues/388
sub finish_and_wait {
    my ($spawn) = @_;

    unless (eval { $spawn->finish; 1 }) {
        my $err = $@;
        die $err unless $err =~ $SERVICE_GONE;
        my $todo = todo('finish() peer-gone race; see #391');
        fail("finish() raced with service exit: $err");
    }

    $spawn->wait;
    $spawn->clear_terminate_on_destroy;
    return;
}

1;
