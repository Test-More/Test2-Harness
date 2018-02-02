package Test2::Harness::UI::Controller::Upload;
use strict;
use warnings;

use Test2::Harness::UI::Import;
use Test2::Harness::UI::Util::Errors qw/ERROR_405 ERROR_404 ERROR_401/;

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;

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

    my $file  = $req->uploads->{log_file}->tempname;
    my $name  = $req->parameters->{feed_name} || $req->uploads->{log_file}->filename;
    my $perms = $req->parameters->{permissions} || 'private';

    my $import = Test2::Harness::UI::Import->new(
        schema      => $self->{+SCHEMA},
        feed_name   => $name,
        file        => $file,
        filename    => $req->uploads->{log_file}->filename,
        user        => $user,
        permissions => $perms,
    );

    my $stat = $import->run;

    use Data::Dumper;
    print Dumper($stat);

    return $self->add_message("Upload Success, imported $stat->{success} event(s).") if defined $stat->{success};

    push @{$self->{+MESSAGES} ||= []} => @{$stat->{errors} || []};
}

sub api_user {
    my $self = shift;
    my ($key_val) = @_;

    return unless $key_val;

    my $schema = $self->{+SCHEMA};
    my $key = $schema->resultset('APIKey')->find({value => $key_val})
        or return undef;

    return undef unless $key->status eq 'active';

    return $key->user;
}

1;
__END__

$VAR1 = bless( {
                 'log_file' => bless( {
                                        'headers' => bless( {
                                                              'content-type' => 'application/x-bzip',
                                                              'content-disposition' => 'form-data; name="log_file"; filename="2018-02-01~13:30:24~1517520624~9587.jsonl.bz2"'
                                                            }, 'HTTP::Headers::Fast' ),
                                        'size' => 167108,
                                        'filename' => '2018-02-01~13:30:24~1517520624~9587.jsonl.bz2',
                                        'tempname' => '/tmp/AFyEe/82jQDZIxHQ'
                                      }, 'Plack::Request::Upload' )
               }, 'Hash::MultiValue' );
$VAR2 = bless( {
                 'api_key' => 'fasdfas',
                 'action' => 'Upload Log'
               }, 'Hash::MultiValue' );


    my $user = $req->user
        or return ($self->login(), ['Content-Type' => 'text/html']);

    my $template = share_dir('templates/user.tx');
    my $tx       = Text::Xslate->new();
    my $sort_val = {active => 1, disabled => 2, revoked => 3};
    my $content = $tx->render(
        $template,
        {
            base_uri => $self->base_uri,
            user     => $user,
            keys     => [sort { $sort_val->{$a->status} <=> $sort_val->{$b->status} } $user->api_keys->all],
            errors   => $self->{+ERRORS} || [],
            messages => $self->{+MESSAGES} || [],
        }
    );

    return ($content, ['Content-Type' => 'text/html']);
}


__END__
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
    my $key = $schema->resultset('APIKey')->find({value => $api_key})
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
