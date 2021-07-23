package Test2::Harness::UI::Schema::Result::Coverage;
use utf8;
use strict;
use warnings;

our $VERSION = '0.000075';
@Test2::Harness::UI::Schema::Result::Coverage::ISA = ('DBIx::Class::Core');

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

__PACKAGE__->inflate_column(
    coverage => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('coverage', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('coverage', {}),
    },
);

1;
