package Test2::Harness::UI::Controller::User;
use strict;
use warnings;

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $self->process_form($res) if keys %{$req->parameters};

    my $user = $req->user;

    unless($user) {
        $res->raw_body($self->login());
        return $res;
    }

    $self->{+TITLE} = 'User Settings';

    my $template = share_dir('templates/user.tx');
    my $tx       = Text::Xslate->new();
    my $sort_val = {active => 1, disabled => 2, revoked => 3};
    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            keys     => [sort { $sort_val->{$a->status} <=> $sort_val->{$b->status} } $user->api_keys->all],
        }
    );

    $res->raw_body($content);
    return $res;
}

my %ACTION_MAP = (enable => 'active', disable => 'disabled', revoke => 'revoked');
sub process_form {
    my $self = shift;
    my ($res) = @_;

    my $req    = $self->{+REQUEST};
    my $schema = $self->schema;

    my $p = $req->parameters;

    my $action = lc($p->{action});

    # This one we allow non-post, all others need post.
    if ('logout' eq $action) {
        $req->session_host->update({'user_id' => undef});
        return $res->add_msg("You have been logged out.");
    }

    die error(405) unless $req->method eq 'POST';

    if ('login' eq $action) {
        my $username = $p->{username} or return $res->add_error("username is required");
        my $password = $p->{password} or return $res->add_error("password is required");

        my $user = $schema->resultset('User')->find({username => $username});

        return $res->add_error("Invalid username or password")
            unless $user && $user->verify_password($password);

        $req->session_host->update({'user_id' => $user->user_id});
        return $res->add_msg("You have been logged in.");
    }

    if ('generate key' eq $action) {
        my $key_name = $p->{key_name} or return $res->add_error("a key name is required");
        my $user = $req->user or return $res->add_error("You must be logged in");

        my $key = $user->gen_api_key($key_name);

        return $res->add_msg("Key '$key_name' generated: " . $key->value);
    }

    if ('change password' eq $action) {
        my $user = $req->user or return $res->add_error("You must be logged in");
        my $old_password = $p->{old_password} or return $res->add_error("current password is required");
        my $new_password_1 = $p->{new_password_1} or return $res->add_error("new password is required");
        my $new_password_2 = $p->{new_password_2} or return $res->add_error("new password (again) is required");

        return $res->add_error("New password fields do not match")
            unless $new_password_1 eq $new_password_2;

        return $res->add_error("Incorrect password") unless $user->verify_password($old_password);

        $user->set_password($new_password_1);

        return $res->add_msg("Password Changed.");
    }

    if ($ACTION_MAP{$action}) {
        my $user = $req->user or return $res->add_error("You must be logged in");
        my $key_id = $p->{api_key_id} or return $res->add_error("A key id is required");
        my $key = $schema->resultset('ApiKey')->find({api_key_id => $key_id, user_id => $user->user_id});

        return $res->add_error("Invalid key") unless $key;

        $key->update({status => $ACTION_MAP{$action}});
        return $res->add_msg("Key status changed.");
    }
}

sub login {
    my $self = shift;

    $self->{+TITLE} = 'Login';

    my $template = share_dir('templates/login.tx');

    my $tx = Text::Xslate->new();
    return $tx->render(
        $template,
        {
            base_uri => $self->{+REQUEST}->base->as_string,
        }
    );
}

1;
