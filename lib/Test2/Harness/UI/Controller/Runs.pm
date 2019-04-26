package Test2::Harness::UI::Controller::Runs;
use strict;
use warnings;

use Data::GUID;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Runs' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    my $user = $req->user;
    my $schema = $self->{+CONFIG}->schema;

    die error(404 => 'Missing route') unless $route;

    my $p = $req->parameters;

    my $a = {order_by => { -desc => [qw/added status project_id version/]}};
    my $q = [{permissions => 'public'}];
    if ($user) {
        push @$q => {permissions => 'protected'};
        push @$q => {'me.user_id' => $user->user_id};

        push @{$a->{join}} => 'run_shares';
        push @$q => {'run_shares.user_id' => $user->user_id};
    }

    my $runs = $schema->resultset('Run')->search($q, $a);

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl',
        resultset    => $runs,
    );

    return $res;
}

1;
