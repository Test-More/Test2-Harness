package Test2::Harness::UI::Controller::Job;
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

    my $schema = $self->{+CONFIG}->schema;
    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No id');

    my $job = $schema->resultset('Job')->search({job_id => $it})->first or die error(404 => 'Invalid Job');
    $job->verify_access('r', $user) or die error(404 => 'Invalid Job');

    $self->{+TITLE} = 'Job: ' . ($job->file || $job->name) . ' - ' . $job->job_id;

    my $ct = lc($req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html');

    if ($ct eq 'application/json') {
        $res->content_type($ct);
        $res->raw_body($job);
        return $res;
    }

    my $template = share_dir('templates/job.tx');
    my $tx       = Text::Xslate->new();
    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            job      => encode_json($job),
            job_id   => $job->job_id,
        }
    );

    $res->raw_body($content);
    return $res;
}

1;

