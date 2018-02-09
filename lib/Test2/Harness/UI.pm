package Test2::Harness::UI;
use strict;
use warnings;

our $VERSION = '0.000001';

use Router::Simple;

use Test2::Harness::UI::Request;
use Test2::Harness::UI::Controller::Page;
use Test2::Harness::UI::Controller::Upload;
use Test2::Harness::UI::Controller::User;

use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::UI::Util::Errors qw/ERROR_404 ERROR_405 ERROR_401 is_error_code/;

use Test2::Harness::UI::Util::HashBase qw/-config -router/;

sub init {
    my $self = shift;

    my $router = $self->{+ROUTER} ||= Router::Simple->new;

    $router->connect('/'           => {controller => 'Page'});
    $router->connect(qr'/user/?'   => {controller => 'User'});
    $router->connect(qr'/upload/?' => {controller => 'Upload'});
}

sub to_app {
    my $self = shift;

    my $router = $self->{+ROUTER};

    return sub {
        my $env = shift;

        my $req = Test2::Harness::UI::Request->new(env => $env, config => $self->{+CONFIG});

        my $r = $router->match($env) || {};

        $self->wrap($r->{controller}, $req);
    };
}

sub wrap {
    my $self = shift;
    my ($controller, $req) = @_;

    my ($headers, $content);
    my $ok = eval {
        die ERROR_404() unless $controller;
        my $class = "Test2::Harness::UI::Controller::$controller";

        my $controller = $class->new(request => $req, config => $self->{+CONFIG});
        ($content, $headers) = $controller->process();

        1;
    };
    my $err = $@;

    return [200, $headers, [$content]] if $ok;

    if ($err) {
        if (my $code = is_error_code($err)) {
            return [401, ['Content-Type' => 'text/plain'], ["401 Unauthorized\n"]]
                if $code == 401;

            return [404, ['Content-Type' => 'text/plain'], ["404 page not found\n"]]
                if $code == 404;

            return [405, ['Content-Type' => 'text/plain'], ["405 Method not allowed\n"]]
                if $code == 405;
        }

        return [500, ['Content-Type' => 'text/plain'], ["$err\n"]]
            if $ENV{T2_HARNESS_UI_ENV} eq 'dev';
    }

    return [500, ['Content-Type' => 'text/plain'], ["Internal Server Error\n"]];
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
