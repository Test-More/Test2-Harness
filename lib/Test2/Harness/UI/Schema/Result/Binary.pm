package Test2::Harness::UI::Schema::Result::Binary;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000132';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/Binary.pm";
require "Test2/Harness/UI/Schema/Overlay/Binary.pm";

1;
