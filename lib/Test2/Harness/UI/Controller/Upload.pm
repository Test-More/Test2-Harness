package Test2::Harness::UI::Controller::Upload;
use strict;
use warnings;

use File::Temp qw/tempfile/;

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Util::Errors qw/ERROR_405 ERROR_404 ERROR_401/;

use Test2::Harness::UI::Import();
use Text::Xslate();

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-key/;
use Test2::Harness::UI::ControllerRole::UseSession;
use Test2::Harness::UI::ControllerRole::HTML;

sub title { 'upload' }

sub process_request {
    my $self = shift;

    my $req = $self->request;

    $self->process_form() if keys %{$req->parameters};

    my $template = share_dir('templates/upload.tx');
    my $tx       = Text::Xslate->new();
    my $user     = $req->user;

    my $content = $tx->render(
        $template,
        {
            base_uri => $self->base_uri,
            user     => $user,
            errors   => $self->{+ERRORS} || [],
            messages => $self->{+MESSAGES} || [],
        }
    );

    return ($content, ['Content-Type' => 'text/html']);
}

sub process_form {
    my $self = shift;

    my $req = $self->request;

    die ERROR_405 unless $req->method eq 'POST';

    return unless 'upload log' eq lc($req->parameters->{action});

    my $user = $req->user || $self->api_user($req->parameters->{api_key});
    die ERROR_401 unless $user;

    my $ud = $self->{+CONFIG}->upload_dir;

    my $orig = $req->uploads->{log_file}->filename;
    rename($req->uploads->{log_file}->tempname, "$ud/$orig") or die "Could not move feed file: $!";

    my $name          = $req->parameters->{feed_name}     || $orig;
    my $perms         = $req->parameters->{permissions}   || 'private';
    my $mode          = $req->parameters->{mode}          || 'qvfd';
    my $store_orphans = $req->parameters->{store_orphans} || 'fail';
    my $store_facets  = $req->parameters->{store_facets}  || 'fail';

    my $run = $self->{+SCHEMA}->resultset('Run')->create(
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

    return $self->add_message("Upload Success, added import to queue");
}

sub api_user {
    my $self = shift;
    my ($key_val) = @_;

    return unless $key_val;

    my $schema = $self->{+SCHEMA};
    my $key = $schema->resultset('ApiKey')->find({value => $key_val})
        or return undef;

    return undef unless $key->status eq 'active';

    return $key->user;
}

1;
