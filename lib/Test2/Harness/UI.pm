package Test2::Harness::UI;
use strict;
use warnings;

our $VERSION = '0.000001';

use Router::Simple;
use Text::Xslate(qw/mark_raw/);
use Scalar::Util qw/blessed/;

use Test2::Harness::UI::Request;
use Test2::Harness::UI::Controller::Dashboard;
use Test2::Harness::UI::Controller::Upload;
use Test2::Harness::UI::Controller::User;
use Test2::Harness::UI::Controller::Run;
use Test2::Harness::UI::Controller::Job;

use Test2::Harness::UI::Controller::Query;
use Test2::Harness::UI::Controller::Runs;
use Test2::Harness::UI::Controller::Jobs;
use Test2::Harness::UI::Controller::Events;

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Test2::Harness::UI::Util::HashBase qw/-config -router/;

sub init {
    my $self = shift;

    my $router = $self->{+ROUTER} ||= Router::Simple->new;

    $router->connect('/'          => {controller => 'Test2::Harness::UI::Controller::Dashboard'});
    $router->connect('/dashboard' => {controller => 'Test2::Harness::UI::Controller::Dashboard'});

    $router->connect('/runs' => {controller => 'Test2::Harness::UI::Controller::Runs'});

    $router->connect('/query/:name'      => {controller => 'Test2::Harness::UI::Controller::Query'});
    $router->connect('/query/:name/:arg' => {controller => 'Test2::Harness::UI::Controller::Query'});

    $router->connect('/run/:id' => {controller => 'Test2::Harness::UI::Controller::Run'});
    $router->connect('/job/:id' => {controller => 'Test2::Harness::UI::Controller::Job'});

    $router->connect('/run/:id/jobs'        => {controller => 'Test2::Harness::UI::Controller::Jobs',   from => 'run'});
    $router->connect('/job/:id/events'      => {controller => 'Test2::Harness::UI::Controller::Events', from => 'job'});
    $router->connect('/event/:id/events'    => {controller => 'Test2::Harness::UI::Controller::Events', from => 'event'});

    $router->connect('/user'   => {controller => 'Test2::Harness::UI::Controller::User'});
    $router->connect('/upload' => {controller => 'Test2::Harness::UI::Controller::Upload'});
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
            my $msg = $ENV{T2_HARNESS_UI_ENV} eq 'dev' ? "$err\n" : undef;
            $res = error(500 => $msg);
        }
    }

    my $ct = $res->content_type();
    $ct ||= do { $res->content_type('text/html'); 'text/html' };
    $ct = lc($ct);

    if (my $stream = $res->stream) {
        return $stream;
    }

    if ($ct eq 'text/html') {
        my $template = share_dir('templates/main.tx');

        my $tx      = Text::Xslate->new();
        my $wrapped = $tx->render(
            $template,
            {
                config => $self->{+CONFIG},

                user     => $req->user     || undef,
                errors   => $res->errors   || [],
                messages => $res->messages || [],
                add_css  => $res->css      || [],
                add_js   => $res->js       || [],
                title    => $res->title    || ($controller ? $controller->title : 'Test2-Harness-UI'),

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

Test2::Harness::UI - Work in progress

=head1 DESCRIPTION

Work in progress

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2018 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
