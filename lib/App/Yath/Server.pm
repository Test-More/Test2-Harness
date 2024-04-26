package App::Yath::Server;
use strict;
use warnings;

our $VERSION = '2.000000';

use Router::Simple;
use Text::Xslate(qw/mark_raw/);
use Scalar::Util qw/blessed/;
use DateTime;

use App::Yath::Server::Request;
use App::Yath::Server::Controller::Upload;
use App::Yath::Server::Controller::Recent;
use App::Yath::Server::Controller::User;
use App::Yath::Server::Controller::Run;
use App::Yath::Server::Controller::RunField;
use App::Yath::Server::Controller::Job;
use App::Yath::Server::Controller::JobField;
use App::Yath::Server::Controller::Download;
use App::Yath::Server::Controller::Sweeper;
use App::Yath::Server::Controller::Project;
use App::Yath::Server::Controller::Resources;

use App::Yath::Server::Controller::Stream;
use App::Yath::Server::Controller::View;
use App::Yath::Server::Controller::Lookup;

use App::Yath::Server::Controller::Query;
use App::Yath::Server::Controller::Events;

use App::Yath::Server::Controller::Durations;
use App::Yath::Server::Controller::Coverage;
use App::Yath::Server::Controller::Files;
use App::Yath::Server::Controller::ReRun;

use App::Yath::Server::Controller::Interactions;
use App::Yath::Server::Controller::Binary;

use App::Yath::Server::Util qw/share_dir/;
use App::Yath::Server::Response qw/resp error/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::Util::HashBase qw/-config -router/;

sub init {
    my $self = shift;

    my $router = $self->{+ROUTER} ||= Router::Simple->new;
    my $config = $self->{+CONFIG};

    $router->connect('/' => {controller => 'App::Yath::Server::Controller::View'});

    $router->connect('/upload' => {controller => 'App::Yath::Server::Controller::Upload'})
        unless $config->single_run;

    $router->connect('/user' => {controller => 'App::Yath::Server::Controller::User'})
        unless $config->single_user;

    $router->connect('/resources/data/:id'        => {controller => 'App::Yath::Server::Controller::Resources', data => 1});
    $router->connect('/resources/data/:id/'       => {controller => 'App::Yath::Server::Controller::Resources', data => 1});
    $router->connect('/resources/data/:id/:batch' => {controller => 'App::Yath::Server::Controller::Resources', data => 1});
    $router->connect('/resources/:id'             => {controller => 'App::Yath::Server::Controller::Resources'});
    $router->connect('/resources/:id/'            => {controller => 'App::Yath::Server::Controller::Resources'});
    $router->connect('/resources/:id/:batch'      => {controller => 'App::Yath::Server::Controller::Resources'});

    $router->connect('/interactions/:id'               => {controller => 'App::Yath::Server::Controller::Interactions'});
    $router->connect('/interactions/:id/:context'      => {controller => 'App::Yath::Server::Controller::Interactions'});
    $router->connect('/interactions/data/:id'          => {controller => 'App::Yath::Server::Controller::Interactions', data => 1});
    $router->connect('/interactions/data/:id/:context' => {controller => 'App::Yath::Server::Controller::Interactions', data => 1});

    $router->connect('/project/:id'           => {controller => 'App::Yath::Server::Controller::Project'});
    $router->connect('/project/:id/stats'     => {controller => 'App::Yath::Server::Controller::Project', stats => 1});
    $router->connect('/project/:id/:n'        => {controller => 'App::Yath::Server::Controller::Project'});
    $router->connect('/project/:id/:n/:count' => {controller => 'App::Yath::Server::Controller::Project'});

    $router->connect('/recent/:project/:user/:count' => {controller => 'App::Yath::Server::Controller::Recent'});
    $router->connect('/recent/:project/:user'        => {controller => 'App::Yath::Server::Controller::Recent'});

    $router->connect('/query/:name'      => {controller => 'App::Yath::Server::Controller::Query'});
    $router->connect('/query/:name/:arg' => {controller => 'App::Yath::Server::Controller::Query'});

    $router->connect('/run/:id'            => {controller => 'App::Yath::Server::Controller::Run'});
    $router->connect('/run/:id/pin'        => {controller => 'App::Yath::Server::Controller::Run', action => 'pin_toggle'});
    $router->connect('/run/:id/delete'     => {controller => 'App::Yath::Server::Controller::Run', action => 'delete'});
    $router->connect('/run/:id/cancel'     => {controller => 'App::Yath::Server::Controller::Run', action => 'cancel'});
    $router->connect('/run/:id/parameters' => {controller => 'App::Yath::Server::Controller::Run', action => 'parameters'});

    $router->connect('/run/field/:id'        => {controller => 'App::Yath::Server::Controller::RunField'});
    $router->connect('/run/field/:id/delete' => {controller => 'App::Yath::Server::Controller::RunField', action => 'delete'});

    $router->connect('/job/field/:id'        => {controller => 'App::Yath::Server::Controller::JobField'});
    $router->connect('/job/field/:id/delete' => {controller => 'App::Yath::Server::Controller::JobField', action => 'delete'});

    $router->connect('/job/:job'         => {controller => 'App::Yath::Server::Controller::Job'});
    $router->connect('/job/:job/:try'    => {controller => 'App::Yath::Server::Controller::Job'});
    $router->connect('/event/:id'        => {controller => 'App::Yath::Server::Controller::Events', from => 'single_event'});
    $router->connect('/event/:id/events' => {controller => 'App::Yath::Server::Controller::Events', from => 'event'});

    $router->connect('/durations/:project'                => {controller => 'App::Yath::Server::Controller::Durations'});
    $router->connect('/durations/:project/median'         => {controller => 'App::Yath::Server::Controller::Durations', median => 1});
    $router->connect('/durations/:project/median/:user'   => {controller => 'App::Yath::Server::Controller::Durations', median => 1});
    $router->connect('/durations/:project/:short/:medium' => {controller => 'App::Yath::Server::Controller::Durations'});

    $router->connect('/coverage/:source'        => {controller => 'App::Yath::Server::Controller::Coverage'});
    $router->connect('/coverage/:source/:user'  => {controller => 'App::Yath::Server::Controller::Coverage'});
    $router->connect('/coverage/:source/delete' => {controller => 'App::Yath::Server::Controller::Coverage', delete => 1});

    $router->connect('/failed/:source'                 => {controller => 'App::Yath::Server::Controller::Files', failed => 1});
    $router->connect('/failed/:source/json'            => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});
    $router->connect('/failed/:project/:idx'           => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});
    $router->connect('/failed/:project/:username/:idx' => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});

    $router->connect('/files/:source'                 => {controller => 'App::Yath::Server::Controller::Files', failed => 0});
    $router->connect('/files/:source/json'            => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});
    $router->connect('/files/:project/:idx'           => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});
    $router->connect('/files/:project/:username/:idx' => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});

    $router->connect('/rerun/:run_id'            => {controller => 'App::Yath::Server::Controller::ReRun'});
    $router->connect('/rerun/:project/:username' => {controller => 'App::Yath::Server::Controller::ReRun'});

    $router->connect('/binary/:binary_id' => {controller => 'App::Yath::Server::Controller::Binary'});

    $router->connect('/download/:id' => {controller => 'App::Yath::Server::Controller::Download'});

    $router->connect('/lookup'              => {controller => 'App::Yath::Server::Controller::Lookup'});
    $router->connect('/lookup/:lookup'      => {controller => 'App::Yath::Server::Controller::Lookup'});
    $router->connect('/lookup/data/:lookup' => {controller => 'App::Yath::Server::Controller::Lookup', data => 1});

    $router->connect('/view'                   => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:id'               => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:run_id/:job'      => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:run_id/:job/:try' => {controller => 'App::Yath::Server::Controller::View'});

    $router->connect('/stream/run/:run_id'       => {controller => 'App::Yath::Server::Controller::Stream', run_only => 1});
    $router->connect('/stream'                   => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:id'               => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:run_id/:job'      => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:run_id/:job/:try' => {controller => 'App::Yath::Server::Controller::Stream'});

    $router->connect('/sweeper/:count/days'    => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'day'});
    $router->connect('/sweeper/:count/hours'   => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'hour'});
    $router->connect('/sweeper/:count/minutes' => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'minute'});
    $router->connect('/sweeper/:count/seconds' => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'second'});
}

sub to_app {
    my $self = shift;

    my $router = $self->{+ROUTER};

    return sub {
        my $env = shift;

        my $req = App::Yath::Server::Request->new(env => $env, config => $self->{+CONFIG});

        my $r = $router->match($env) || {};

        $self->wrap($r->{controller}, $req, $r);
    };
}

sub wrap {
    my $self = shift;
    my ($class, $req, $r) = @_;

    my ($controller, $res, $session);
    my $ok = eval {
        die error(404) unless $class;

        if ($class->uses_session) {
            $session = $req->session;
            $req->session_host; # vivify this
        }

        $controller = $class->new(request => $req, config => $self->{+CONFIG});
        $res = $controller->handle($r);

        1;
    };
    my $err = $@ || 'Internal Error';

    unless ($ok && $res) {
        if (blessed($err) && $err->isa('App::Yath::Server::Response')) {
            $res = $err;
        }
        else {
            warn $err;
            my $msg = ($ENV{T2_HARNESS_UI_ENV} || '') eq 'dev' ? "$err\n" : undef;
            $res = error(500 => $msg);
        }
    }

    my $ct = $r->{json} ? 'application/json' : blessed($res) ? $res->content_type() : 'text/html';
    $ct ||= 'text/html';
    $ct = lc($ct);
    $res->content_type($ct) if blessed($res);

    if (my $stream = $res->stream) {
        return $stream;
    }

    if ($ct eq 'text/html') {
        my $dt = DateTime->now(time_zone => 'local');

        my $tx      = Text::Xslate->new(path => [share_dir('templates')]);
        my $wrapped = $tx->render(
            'main.tx',
            {
                config => $self->{+CONFIG},

                user     => $req->user     || undef,
                errors   => $res->errors   || [],
                messages => $res->messages || [],
                add_css  => $res->css      || [],
                add_js   => $res->js       || [],
                title    => $res->title    || ($controller ? $controller->title : 'Test2-Harness-UI'),

                time_zone => $dt->strftime("%Z"),

                base_uri => $req->base->as_string || '',
                content  => mark_raw($res->raw_body)  || '',
            }
        );

        $res->body($wrapped);
    }
    elsif($ct eq 'application/json') {
        if (my $data = $res->raw_body) {
            $res->body(ref($data) ? encode_json($data) : $data);
        }
        elsif (my $errors = $res->errors) {
            $res->body(encode_json({errors => $errors}));
        }
    }

    $res->cookies->{id} = {value => $session->session_id, httponly => 1, expires => '+1M'}
        if $session;

    return $res->finalize;
}


__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server - Web interface for viewing and inspecting yath test logs

=head1 EARLY VERSION WARNING

This program is still in early development. There are many bugs, missing
features, and things that will change.

=head1 DESCRIPTION

This package provides a web UI for yath logs.

=head1 SYNOPSIS

The easiest thing to do is use the C<yath ui path/to/logfile> command, which
will create a temporary postgresql db, load your log into it, then launch the
app in starman on a local port that you can visit in your browser.

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<https://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
