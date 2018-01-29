package Test2::Harness::UI;
use strict;
use warnings;

use Test2::Harness::UI::Util::HashBase qw/-config_file/;

use Plack::Builder;
use Test2::Harnes::UI::Controller::Feed;

sub schema {
    my $self = shift;
}

sub to_app {
    my $self = shift;

    return builder {
        mount "/feed" => Test2::Harnes::UI::Controller::Feed->new(ui => $self)->to_app;

        mount "/" => sub {
            my $env = shift;

            return ['200', ['Content-Type' => 'text/html'], ["<html>Hello World</html>"]];
        };
    };
}
