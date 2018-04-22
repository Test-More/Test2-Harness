package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

use Data::GUID;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Dashboard';

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_js('dashboard.js');

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

    $res->raw_body($content);
    return $res;
}

1;
