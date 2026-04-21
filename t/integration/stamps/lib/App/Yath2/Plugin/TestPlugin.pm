package App::Yath2::Plugin::TestPlugin;
use strict;
use warnings;

use Test2::Harness2::Util::JSON qw/encode_json/;

use parent 'App::Yath2::Plugin';

sub handle_event {
    my $self = shift;
    my ($event) = @_;

    die "Event did not have a stamp!" unless $event->stamp;
}

1;
