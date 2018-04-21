package Test2::Harness::UI::Controller::Run;
use strict;
use warnings;

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('dashboard.css');
    $res->add_css('run.css');
    $res->add_css('job.css');
    $res->add_css('event.css');
    $res->add_js('dashboard.js');
    $res->add_js('run.js');
    $res->add_js('job.js');
    $res->add_js('event.js');

    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No id');
    my $query = [{run_id => $it}];

    my $run = $user->runs($query)->first or die error(404 => 'Invalid run');

    $self->{+TITLE} = 'Run: ' . $run->project . ' - ' . $run->run_id;

    my $ct = lc($req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html');

    if ($ct eq 'application/json') {
        $res->content_type($ct);
        $res->raw_body($run);
        return $res;
    }

    my $template = share_dir('templates/run.tx');
    my $tx       = Text::Xslate->new();
    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            run      => encode_json($run),
            run_id   => $run->run_id,
        }
    );

    $res->raw_body($content);
    return $res;
}

1;
