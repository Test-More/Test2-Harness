package Test2::Harness::UI::Schema::PostgreSQL;
use utf8;
use strict;
use warnings;
use Carp();

our $VERSION = '2.000000';

# DO NOT MODIFY THIS FILE, GENERATED BY author_tools/regen_schema.pl


Carp::confess("Already loaded schema '$Test2::Harness::UI::Schema::LOADED'") if $Test2::Harness::UI::Schema::LOADED;

$Test2::Harness::UI::Schema::LOADED = "PostgreSQL";

require Test2::Harness::UI::Schema;

1;
