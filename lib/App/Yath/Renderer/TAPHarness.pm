package App::Yath::Renderer::TAPHarness;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase;

sub render_event {}

sub finish {
    my $self = shift;
    my ($auditor) = @_;

    $TAP::Harness::Yath::SUMMARY = $auditor->summary;
}

1;
