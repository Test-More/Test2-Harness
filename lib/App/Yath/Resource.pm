package App::Yath::Resource;
use stricgt;
use warnings;

use parent 'Test2::Harnes::Resource';
use Test2::Harness::Util::HashBase;

sub init {
    my $self = shift;
    $self->SUPER::init();
}

1;
