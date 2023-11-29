package App::Yath::Command::abort;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;

use App::Yath::Client;

use Test2::Harness::IPC::Util qw/pid_is_running/;
use Test2::Harness::Util::JSON qw/decode_json/;

use parent 'App::Yath::Command::watch';
use Test2::Harness::Util::HashBase;

sub summary { "Abort running tests without killing the runner" }

sub process_name { 'yath-abort' }

warn "FIXME";
sub description {
    return <<"    EOT";
    FIXME
    EOT
}

sub run {
    my $self = shift;

    $0 = $self->process_name;

    $self->client->send_and_get('abort');

    return 0;
}

1;
