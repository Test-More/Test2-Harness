package Test2::Harness::UI::Controller::Upload;
use strict;
use warnings;

use Text::Xslate();

use Test2::Harness::UI::Import();

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Upload' }

sub handle {
    my $self = shift;

    my $req = $self->request;

    my $res = resp(200);
    $self->process_form($res) if keys %{$req->parameters};

    my $template = share_dir('templates/upload.tx');
    my $tx       = Text::Xslate->new();
    my $user     = $req->user;

    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
        }
    );

    $res->body($content);
    return $res;
}

sub process_form {
    my $self = shift;
    my ($res) = @_;

    my $req = $self->{+REQUEST};

    die error(405) unless $req->method eq 'POST';

    return unless 'upload log' eq lc($req->parameters->{action});

    my $user = $req->user || $self->api_user($req->parameters->{api_key});
    die error(401) unless $user;

    my $ud = $self->{+CONFIG}->upload_dir;

    my $orig = $req->uploads->{log_file}->filename;
    rename($req->uploads->{log_file}->tempname, "$ud/$orig") or die "Could not move feed file: $!";

    my $name          = $req->parameters->{feed_name}     || $orig;
    my $perms         = $req->parameters->{permissions}   || 'private';
    my $mode          = $req->parameters->{mode}          || 'qvfd';
    my $store_orphans = $req->parameters->{store_orphans} || 'fail';
    my $store_facets  = $req->parameters->{store_facets}  || 'fail';

    my $run = $self->schema->resultset('Run')->create(
        {
            user_id       => $user->user_id,
            name          => $name,
            permissions   => $perms,
            mode          => $mode,
            store_orphans => $store_orphans,
            store_facets  => $store_facets,
            log_file      => "$ud/$orig",
            status        => 'pending',
        }
    );

    return $res->add_message("Upload Success, added import to queue");
}

sub api_user {
    my $self = shift;
    my ($key_val) = @_;

    return unless $key_val;

    my $schema = $self->schema;
    my $key = $schema->resultset('ApiKey')->find({value => $key_val})
        or return undef;

    return undef unless $key->status eq 'active';

    return $key->user;
}

1;
