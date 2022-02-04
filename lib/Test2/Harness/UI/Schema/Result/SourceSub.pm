package Test2::Harness::UI::Schema::Result::SourceSub;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000108';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/SourceSub.pm";
require "Test2/Harness/UI/Schema/Overlay/SourceSub.pm";

1;
