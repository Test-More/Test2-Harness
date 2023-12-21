package App::Yath::Command;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec;
use Carp qw/croak/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Util::HashBase qw/<settings <args <env_vars <option_state <plugins/;

sub args_include_tests { 0 }
sub internal_only      { 0 }
sub summary            { "No Summary" }
sub description        { "No Description" }
sub group              { "Z-FIXME" }

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub name { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }

sub run {
    my $self = shift;

    warn "This command is currently empty.\n";

    return 1;
}

1;
