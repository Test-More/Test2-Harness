package Test2::Harness::UI::Schema::Result::Job;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000138';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/Job.pm";
require "Test2/Harness/UI/Schema/Overlay/Job.pm";

1;
