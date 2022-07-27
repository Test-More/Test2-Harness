package Test2::Harness::UI::Schema::Result::TestFile;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000124';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/TestFile.pm";
require "Test2/Harness/UI/Schema/Overlay/TestFile.pm";

1;
