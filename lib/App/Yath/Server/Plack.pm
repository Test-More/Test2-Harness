package App::Yath::Server::Plack;
use strict;
use warnings;

our $VERSION = '2.000005';

use Router::Simple;
use DateTime;

use Text::Xslate(qw/mark_raw/);
use Scalar::Util qw/blessed/;
use Carp qw/croak/;

use Plack::Builder;
use Plack::App::Directory;
use Plack::App::File;

use App::Yath::Server::Request;
use App::Yath::Server::Controller::Upload;
use App::Yath::Server::Controller::Recent;
use App::Yath::Server::Controller::User;
use App::Yath::Server::Controller::Run;
use App::Yath::Server::Controller::RunField;
use App::Yath::Server::Controller::Job;
use App::Yath::Server::Controller::JobTryField;
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

use App::Yath::Server::Response qw/resp error/;

use App::Yath::Util qw/share_dir/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::Util::HashBase qw{
    <schema_config
    <single_run
    <single_user

    +router
    +app
};

sub init {
    my $self = shift;

    croak "'schema_config' is a required attribute" unless $self->{+SCHEMA_CONFIG};

    my $schema = $self->schema;
    $self->{+SINGLE_RUN}  //= $schema->config('single_run');
    $self->{+SINGLE_USER} //= $schema->config('single_user');
}

sub schema { $_[0]->{+SCHEMA_CONFIG}->schema }

sub router {
    my $self = shift;

    return $self->{+ROUTER} if $self->{+ROUTER};

    my $router = Router::Simple->new;
    my $schema = $self->schema;

    $router->connect('/' => {controller => 'App::Yath::Server::Controller::View'});

    $router->connect('/upload' => {controller => 'App::Yath::Server::Controller::Upload'})
        unless $self->single_run;

    $router->connect('/user' => {controller => 'App::Yath::Server::Controller::User'})
        unless $self->single_user;

    $router->connect('/resources/:run_id'             => {controller => 'App::Yath::Server::Controller::Resources'});
    $router->connect('/resources/:run_id/:ord'        => {controller => 'App::Yath::Server::Controller::Resources'});
    $router->connect('/resources/:run_id/data/stream' => {controller => 'App::Yath::Server::Controller::Resources', data => 1});
    $router->connect('/resources/:run_id/data/min'    => {controller => 'App::Yath::Server::Controller::Resources', data => 1, min => 1});
    $router->connect('/resources/:run_id/data/max'    => {controller => 'App::Yath::Server::Controller::Resources', data => 1, max => 1});
    $router->connect('/resources/:run_id/data/:ord'   => {controller => 'App::Yath::Server::Controller::Resources', data => 1});

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

    $router->connect('/job/field/:id'        => {controller => 'App::Yath::Server::Controller::JobTryField'});
    $router->connect('/job/field/:id/delete' => {controller => 'App::Yath::Server::Controller::JobTryField', action => 'delete'});

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

    $router->connect('/failed/:source'                => {controller => 'App::Yath::Server::Controller::Files', failed => 1});
    $router->connect('/failed/:source/json'           => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});
    $router->connect('/failed/:project/:id'           => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});
    $router->connect('/failed/:project/:username/:id' => {controller => 'App::Yath::Server::Controller::Files', failed => 1, json => 1});

    $router->connect('/files/:source'                => {controller => 'App::Yath::Server::Controller::Files', failed => 0});
    $router->connect('/files/:source/json'           => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});
    $router->connect('/files/:project/:id'           => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});
    $router->connect('/files/:project/:username/:id' => {controller => 'App::Yath::Server::Controller::Files', failed => 0, json => 1});

    $router->connect('/rerun/:run_id'            => {controller => 'App::Yath::Server::Controller::ReRun'});
    $router->connect('/rerun/:project/:username' => {controller => 'App::Yath::Server::Controller::ReRun'});

    $router->connect('/binary/:binary_id' => {controller => 'App::Yath::Server::Controller::Binary'});

    $router->connect('/download/:id' => {controller => 'App::Yath::Server::Controller::Download'});

    $router->connect('/lookup'              => {controller => 'App::Yath::Server::Controller::Lookup'});
    $router->connect('/lookup/:lookup'      => {controller => 'App::Yath::Server::Controller::Lookup'});
    $router->connect('/lookup/data/:lookup' => {controller => 'App::Yath::Server::Controller::Lookup', data => 1});

    $router->connect('/view'                     => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/project/:project_id' => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/user/:user_id'       => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:run_id'             => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:run_id/:job'        => {controller => 'App::Yath::Server::Controller::View'});
    $router->connect('/view/:run_id/:job/:try'   => {controller => 'App::Yath::Server::Controller::View'});

    $router->connect('/stream'                     => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/run/:run_id'         => {controller => 'App::Yath::Server::Controller::Stream', run_only => 1});
    $router->connect('/stream/user/:user_id'       => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/project/:project_id' => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:run_id'             => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:run_id/:job'        => {controller => 'App::Yath::Server::Controller::Stream'});
    $router->connect('/stream/:run_id/:job/:try'   => {controller => 'App::Yath::Server::Controller::Stream'});

    $router->connect('/sweeper/:count/days'    => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'day'});
    $router->connect('/sweeper/:count/hours'   => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'hour'});
    $router->connect('/sweeper/:count/minutes' => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'minute'});
    $router->connect('/sweeper/:count/seconds' => {controller => 'App::Yath::Server::Controller::Sweeper', units => 'second'});

    return $self->{+ROUTER} = $router;
}

sub to_app {
    my $self = shift;

    return $self->{+APP} //= builder {
        mount '/js'          => Plack::App::Directory->new({root => share_dir('js')})->to_app;
        mount '/css'         => Plack::App::Directory->new({root => share_dir('css')})->to_app;
        mount '/img'         => Plack::App::Directory->new({root => share_dir('img')})->to_app;
        mount '/favicon.ico' => Plack::App::File->new({file => share_dir('img') . '/favicon.ico'})->to_app;
        mount '/'            => sub { $self->handle_request(@_) };
    };
}

sub handle_request {
    my $self = shift;
    my ($env) = @_;

    my $schema = $self->schema;
    my $router           = $self->router;
    my $route            = $router->match($env) || {};
    my $controller_class = $route->{controller} or return error(404);

    my $req = App::Yath::Server::Request->new(env => $env, schema => $schema);

    my ($controller, $res, $session, $session_host, $user);
    my $ok = eval {
        $session      = $req->session();
        $session_host = $req->session_host();

        if ($self->{+SINGLE_USER}) {
            $user = $self->schema->resultset('User')->find({username => 'root'});
        }
        elsif ($session_host) {
            $user = $session_host->user if $session_host->user_id;
        }

        $req->set_user($user) if $user;

        $controller = $controller_class->new(
            request       => $req,
            route         => $route,
            schema        => $self->schema,
            schema_config => $self->schema_config,
            session       => $session,
            session_host  => $session_host,
            single_run    => $self->single_run,
            single_user   => $self->single_user,
            user          => $user,
        );

        $res = $controller->auth_check() // $controller->handle($route);

        1;
    };
    my $err = $@ || 'Internal Error';

    unless ($ok && $res) {
        if (blessed($err) && $err->isa('App::Yath::Server::Response')) {
            $res = $err;
        }
        else {
            warn $err;
            my $msg = ($ENV{T2_HARNESS_SERVER_DEV} || '') eq 'dev' ? "$err\n" : undef;
            $res = error(500 => $msg);
        }
    }

    my $ct = $route->{json} ? 'application/json' : blessed($res) ? $res->content_type() : 'text/html';
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
                single_user => $self->single_user // 0,
                single_run  => $self->single_run  // 0,
                no_upload   => $schema->config('no_upload') // 0,
                show_user   => $self->single_user ? $schema->config('show_user') // 0 : 1,

                user     => $req->user     || undef,
                errors   => $res->errors   || [],
                messages => $res->messages || [],
                add_css  => $res->css      || [],
                add_js   => $res->js       || [],
                title    => $res->title    || ($controller ? $controller->title : 'Yath-Server'),

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

    $res->cookies->{uuid} = {value => $session->session_uuid, httponly => 1, expires => '+1M'}
        if $session;

    return $res->finalize;
}


__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Plack - Plack app module for Yath Server.

=head1 DESCRIPTION


=head1 SYNOPSIS


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

=pod

=cut POD NEEDS AUDIT

