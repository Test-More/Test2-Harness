package Test2::Harness::UI::Schema::Result::Host;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000129';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/Host.pm";
require "Test2/Harness/UI/Schema/Overlay/Host.pm";

1;
