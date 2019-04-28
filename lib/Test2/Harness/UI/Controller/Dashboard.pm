package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

our $VERSION = '0.000001';

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
    $res->add_css('dashboard.css');

    my $user = $req->user;

    my $tx      = Text::Xslate->new(path => [share_dir('templates')]);
    my $content = $tx->render(
        'dashboard.tx',
        {
            base_uri => $req->base->as_string,
            user     => $user,
        }
    );

    $res->raw_body($content);
    return $res;
}

1;
