package Test2::Harness::UI::Controller::Query;
use strict;
use warnings;

our $VERSION = '0.000001';

use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Query' }

my %ALLOWED = (
    projects   => {arg => 0},
    versions   => {arg => 1},
    categories => {arg => 1},
    tiers      => {arg => 1},
    builds     => {arg => 1},
);

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    my $user = $req->user;
    my $schema = $self->{+CONFIG}->schema;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{name} or die error(400 => 'No query specified');
    my $spec = $ALLOWED{$it} or die error(400);
    my $arg = $route->{arg};
    die error(400 => 'Missing Argument') if $spec->{args} && !defined($arg);

    my $q = Test2::Harness::UI::Queries->new(config => $self->{+CONFIG});
    my $data = $q->$it($arg);

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl',

        done  => sub { !@$data },
        fetch => sub {
            my $item = shift @$data or return;
            return encode_json($item) . "\n";
        },
    );

    return $res;
}

1;
