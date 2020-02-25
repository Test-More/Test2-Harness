package App::Yath::Plugin::TestPlugin;
use strict;
use warnings;

use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'App::Yath::Plugin';

sub handle_event {
    my $self = shift;
    my ($event) = @_;

    die "Event did not have a stamp!" unless $event->stamp;
}

1;
