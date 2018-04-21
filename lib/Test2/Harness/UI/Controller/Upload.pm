package Test2::Harness::UI::Controller::Upload;
use strict;
use warnings;

use Text::Xslate();

use Test2::Harness::UI::Import();
use Test2::Harness::UI::Queries();

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Upload A Test Log' }

sub handle {
    my $self = shift;

    my $req = $self->request;

    my $res = resp(200);
    $res->add_css('upload.css');
    $res->add_js('upload.js');

    $self->process_form($res) if $req->parameters->{action};

    my $template = share_dir('templates/upload.tx');
    my $tx       = Text::Xslate->new();
    my $user     = $req->user;

    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            projects => Test2::Harness::UI::Queries->new(config => $self->{+CONFIG})->projects,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub process_form {
    my $self = shift;
    my ($res) = @_;

    my $req = $self->{+REQUEST};

    die error(405) unless $req->method eq 'POST';

    unless( 'upload log' eq lc($req->parameters->{action})) {
        return $res->add_error('Invalid Action');
    }

    my $user = $req->user || $self->api_user($req->parameters->{api_key});
    die error(401) unless $user;

    my $file = $req->uploads->{log_file}->filename;
    my $tmp  = $req->uploads->{log_file}->tempname;

    my $project = $req->parameters->{project} || return $res->add_error('project is required');

    my $version  = $req->parameters->{version};
    my $category = $req->parameters->{category};
    my $tier     = $req->parameters->{tier};
    my $build    = $req->parameters->{build};

    my $perms         = $req->parameters->{permissions}   || 'private';
    my $mode          = $req->parameters->{mode}          || 'qvfd';

    return $res->add_error("Unsupported file type, must be .jsonl.bz2, or .jsonl.gz")
        unless $file =~ m/\.jsonl\.(bz2|gz)$/;

    open(my $fh, '<:raw', $tmp) or die "Could not open uploaded file '$tmp': $!";

    my $run = $self->schema->resultset('Run')->create(
        {
            user_id       => $user->user_id,
            permissions   => $perms,
            mode          => $mode,
            project       => $project,
            version       => $version,
            category      => $category,
            tier          => $tier,
            build         => $build,
            status        => 'pending',

            log_file => {
                name => $file,
                data => do { local $/; <$fh> },
            },
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
