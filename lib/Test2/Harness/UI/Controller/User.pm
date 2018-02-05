package Test2::Harness::UI::Controller::User;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Util::Errors qw/ERROR_405 ERROR_404/;

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/title/;
use Test2::Harness::UI::ControllerRole::UseSession;
use Test2::Harness::UI::ControllerRole::HTML;

sub process_request {
    my $self = shift;

    my $req = $self->request;

    $self->process_form() if keys %{$req->parameters};

    my $user = $req->user
        or return ($self->login(), ['Content-Type' => 'text/html']);

    $self->title('user');

    my $template = share_dir('templates/user.tx');
    my $tx       = Text::Xslate->new();
    my $sort_val = {active => 1, disabled => 2, revoked => 3};
    my $content = $tx->render(
        $template,
        {
            base_uri => $self->base_uri,
            user     => $user,
            keys     => [sort { $sort_val->{$a->status} <=> $sort_val->{$b->status} } $user->api_keys->all],
        }
    );

    return ($content, ['Content-Type' => 'text/html']);
}

my %ACTION_MAP = (enable => 'active', disable => 'disabled', revoke => 'revoked');
sub process_form {
    my $self = shift;

    my $req    = $self->{+REQUEST};
    my $schema = $self->{+SCHEMA};

    my $p = $req->parameters;

    my $action = lc($p->{action});

    # This one we allow non-post, all others need post.
    if ('logout' eq $action) {
        $req->session_host->update({'user_id' => undef});
        return $self->add_msg("You have been logged out.");
    }

    die ERROR_405 unless $req->method eq 'POST';

    if ('login' eq $action) {
        my $username = $p->{username} or return $self->add_error("username is required");
        my $password = $p->{password} or return $self->add_error("password is required");

        my $user = $self->{+SCHEMA}->resultset('User')->find({username => $username});

        return $self->add_error("Invalid username or password")
            unless $user && $user->verify_password($password);

        $req->session_host->update({'user_id' => $user->user_id});
        return $self->add_msg("You have been logged in.");
    }

    if ('generate key' eq $action) {
        my $key_name = $p->{key_name} or return $self->add_error("a key name is required");
        my $user = $req->user or return $self->add_error("You must be logged in");

        my $key = $user->gen_api_key($key_name);

        return $self->add_msg("Key '$key_name' generated: " . $key->value);
    }

    if ('change password' eq $action) {
        my $user = $req->user or return $self->add_error("You must be logged in");
        my $old_password = $p->{old_password} or return $self->add_error("current password is required");
        my $new_password_1 = $p->{new_password_1} or return $self->add_error("new password is required");
        my $new_password_2 = $p->{new_password_2} or return $self->add_error("new password (again) is required");

        return $self->add_error("New password fields do not match")
            unless $new_password_1 eq $new_password_2;

        return $self->add_error("Incorrect password") unless $user->verify_password($old_password);

        $user->set_password($new_password_1);

        return $self->add_msg("Password Changed.");
    }

    if ($ACTION_MAP{$action}) {
        my $user = $req->user or return $self->add_error("You must be logged in");
        my $key_id = $p->{api_key_id} or return $self->add_error("A key id is required");
        my $key = $schema->resultset('ApiKey')->find({api_key_id => $key_id, user_id => $user->user_id});

        return $self->add_error("Invalid key") unless $key;

        $key->update({status => $ACTION_MAP{$action}});
        return $self->add_msg("Key status changed.");
    }
}

sub login {
    my $self = shift;

    $self->title('login');

    my $template = share_dir('templates/login.tx');

    my $tx = Text::Xslate->new();
    return $tx->render(
        $template,
        {
            base_uri => $self->base_uri,
        }
    );
}

1;
