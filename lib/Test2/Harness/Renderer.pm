package Test2::Harness::Renderer;
use strict;
use warnings;

use Test2::Util::HashBase qw/tmpdir/;
use Carp qw/confess/;

sub init {
    my $self = shift;

    confess "'tmpdir' is a required attribute"
        unless $self->{+TMPDIR};
}

sub start  { }
sub loop   { }
sub finish { }

1;
