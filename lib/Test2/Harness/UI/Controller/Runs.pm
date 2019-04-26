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

    my $page = $route->{page} || 1;
    my $size = $route->{size} || 100;

    my $p = $req->parameters;

    my $a = {order_by => { -desc => [qw/added status project_id version/]}};

    my $runs = $schema->resultset('Run')->search(undef, {page => $page, rows => $size, order_by => { -desc => 'added'}});

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl',
        resultset    => $runs,
    );

    return $res;
}

1;
