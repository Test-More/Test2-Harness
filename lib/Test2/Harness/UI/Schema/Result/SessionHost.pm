package Test2::Harness::UI::Schema::Result::SessionHost;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000097';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/SessionHost.pm";
require "Test2/Harness/UI/Schema/Overlay/SessionHost.pm";

1;
