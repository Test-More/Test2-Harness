package Test2::Harness::UI::Controller::API;
use strict;
use warnings;

use Test2::Harness::UI::Import;

use Test2::Harness::UI::Util::Errors qw/ERROR_404/;

use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-key/;

sub process_request {
    my $self = shift;

    my $req = $self->request;

    die ERROR_404 if $req->path ne '/';

    my $json = $req->content;
    my $data;
    my $ok = eval { $data = decode_json($json); 1 };
    my $err = $@;

    my $out = $ok ? $self->handle_payload($data) : {errors => ["JSON decoding error"]};

    return (encode_json($out), ['Content-Type' => 'application/json']);
}

sub handle_payload {
    my $self = shift;
    my ($data) = @_;

    # Verify credentials
    $self->verify_credentials($data) or return {errors => ["Incorrect credentials"]};

    my $action = $data->{action} or return {errors => ["No action specified"]};

    my $meth = "action_$action";
    return {errors => ["Invalid action '$action'"]}
        unless $self->can($meth);

    return $self->$meth($data->{payload});
}

sub verify_credentials {
    my $self = shift;
    my ($data) = @_;

    my $api_key = $data->{api_key} or return;

    my $schema = $self->{+SCHEMA};
    my $key = $schema->resultset('ApiKey')->find({value => $api_key})
        or return undef;

    return undef unless $key->status eq 'active';

    return $self->{+KEY} = $key;
}

sub action_feed {
    my $self = shift;
    my ($payload) = @_;

    my $import = Test2::Harness::UI::Import->new(schema => $self->{+SCHEMA});
    return $import->import_events($self->{+KEY}, $payload);
}

1;
