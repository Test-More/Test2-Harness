package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Dashboard' }

sub handle {
    my $self = shift;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('dashboard.css');

    my $user = $req->user;
    my $template = share_dir('templates/dashboard.tx');
    my $tx       = Text::Xslate->new();
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

1;

__END__

sub handle {
    my $self = shift;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $self->process_form($res) if keys %{$req->parameters};

    my $user = $req->user;

    unless($user) {
        $res->body($self->login());
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

    $res->body($content);
    return $res;
}


