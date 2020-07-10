package Test2::Harness::UI;
use strict;
use warnings;

our $VERSION = '0.000028';

use Router::Simple;
use Text::Xslate(qw/mark_raw/);
use Scalar::Util qw/blessed/;
use DateTime;

use Test2::Harness::UI::Request;
use Test2::Harness::UI::Controller::Dashboard;
use Test2::Harness::UI::Controller::Upload;
use Test2::Harness::UI::Controller::User;
use Test2::Harness::UI::Controller::Run;
use Test2::Harness::UI::Controller::Job;
use Test2::Harness::UI::Controller::Download;

use Test2::Harness::UI::Controller::Query;
use Test2::Harness::UI::Controller::Runs;
use Test2::Harness::UI::Controller::Jobs;
use Test2::Harness::UI::Controller::Events;

use Test2::Harness::UI::Controller::Durations;
use Test2::Harness::UI::Controller::Coverage;

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-config -router/;

sub init {
    my $self = shift;

    my $router = $self->{+ROUTER} ||= Router::Simple->new;
    my $config = $self->{+CONFIG};

    if ($config->single_run) {
        $router->connect('/' => {controller => 'Test2::Harness::UI::Controller::Run'});
    }
    else {
        $router->connect('/'                 => {controller => 'Test2::Harness::UI::Controller::Dashboard'});
        $router->connect('/dashboard'        => {controller => 'Test2::Harness::UI::Controller::Dashboard'});
        $router->connect('/runs'             => {controller => 'Test2::Harness::UI::Controller::Runs'});
        $router->connect('/runs/:page'       => {controller => 'Test2::Harness::UI::Controller::Runs'});
        $router->connect('/runs/:page/:size' => {controller => 'Test2::Harness::UI::Controller::Runs'});
        $router->connect('/upload'           => {controller => 'Test2::Harness::UI::Controller::Upload'});
    }

    $router->connect('/user' => {controller => 'Test2::Harness::UI::Controller::User'})
        unless $config->single_user;

    $router->connect('/query/:name'      => {controller => 'Test2::Harness::UI::Controller::Query'});
    $router->connect('/query/:name/:arg' => {controller => 'Test2::Harness::UI::Controller::Query'});

    $router->connect('/run/:id'          => {controller => 'Test2::Harness::UI::Controller::Run'});
    $router->connect('/run/:id/pin'      => {controller => 'Test2::Harness::UI::Controller::Run', action => 'pin_toggle'});
    $router->connect('/job/:id'          => {controller => 'Test2::Harness::UI::Controller::Job'});
    $router->connect('/run/:id/jobs'     => {controller => 'Test2::Harness::UI::Controller::Jobs',   from => 'run'});
    $router->connect('/job/:id/events'   => {controller => 'Test2::Harness::UI::Controller::Events', from => 'job'});
    $router->connect('/event/:id'        => {controller => 'Test2::Harness::UI::Controller::Events', from => 'single_event'});
    $router->connect('/event/:id/events' => {controller => 'Test2::Harness::UI::Controller::Events', from => 'event'});

    $router->connect('/durations/:project'                => {controller => 'Test2::Harness::UI::Controller::Durations'});
    $router->connect('/durations/:project/:short/:medium' => {controller => 'Test2::Harness::UI::Controller::Durations'});

    $router->connect('/coverage/:project' => {controller => 'Test2::Harness::UI::Controller::Coverage'});

    $router->connect('/download/:id' => {controller => 'Test2::Harness::UI::Controller::Download'});
}

sub to_app {
    my $self = shift;

    my $router = $self->{+ROUTER};

    return sub {
        my $env = shift;

        my $req = Test2::Harness::UI::Request->new(env => $env, config => $self->{+CONFIG});

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
        if (blessed($err) && $err->isa('Test2::Harness::UI::Response')) {
            $res = $err;
        }
        else {
            warn $err;
            my $msg = ($ENV{T2_HARNESS_UI_ENV} || '') eq 'dev' ? "$err\n" : undef;
            $res = error(500 => $msg);
        }
    }

    my $ct = blessed($res) ? $res->content_type() : 'text/html';
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
        $res->body(encode_json($res->raw_body));
    }

    $res->cookies->{id} = {value => $session->session_id, httponly => 1, expires => '+1M'}
        if $session;

    return $res->finalize;
}


__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI - Web interface for viewing and inspecting yath test logs

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
