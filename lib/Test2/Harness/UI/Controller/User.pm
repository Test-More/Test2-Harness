package Test2::Harness::UI::Controller::User;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Util::Errors qw/ERROR_405 ERROR_404/;

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/title errors/;
use Test2::Harness::UI::ControllerRole::UseSession;
use Test2::Harness::UI::ControllerRole::HTML;

sub process_request {
    my $self = shift;

    my $req = $self->request;

    $self->process_form() if keys %{$req->parameters};

    my $user = $req->user
        or return ($self->login(), ['Content-Type' => 'text/html']);

    my $template = share_dir('templates/user.tx');
    my $tx = Text::Xslate->new();
    my $content = $tx->render($template, {user => $user, errors => $self->{+ERRORS} || []});

    return ($content, ['Content-Type' => 'text/html']);
}

sub process_form {
    my $self = shift;
    my $req = $self->request;

    my $p = $req->parameters;

    my $action = lc($p->{action});

    # This one we allow non-post, all others need post.
    if ('logout' eq $action) {
        $req->session_host->update({'user_ui_id' => undef});
        return;
    }

    die ERROR_405 unless $req->method eq 'POST';

    if ('login' eq $action) {
        my $username = $p->{username} or return $self->add_error("username is required");
        my $password = $p->{password} or return $self->add_error("password is required");

        my $user = $self->{+SCHEMA}->resultset('User')->find({username => $username});

        return $self->add_error("Invalid username or password")
            unless $user && $user->verify_password($password);

        $req->session_host->update({'user_ui_id' => $user->user_ui_id});
        return;
    }
}

sub add_error {
    my $self = shift;

    push @{$self->{+ERRORS}} => @_;

    return;
}

sub login {
    my $self = shift;

    $self->title('login');

    my $template = share_dir('templates/login.tx');

    my $tx = Text::Xslate->new();
    return $tx->render($template, {errors => $self->{+ERRORS} || []});
}

1;
