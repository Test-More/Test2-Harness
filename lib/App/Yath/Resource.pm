package App::Yath::Resource;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'Test2::Harness::Resource';
use Test2::Harness::Util::HashBase qw{
    <settings
};

sub init {
    my $self = shift;
    $self->SUPER::init();

    croak "'settings' is a required attribute" unless $self->{+SETTINGS};
}

1;
