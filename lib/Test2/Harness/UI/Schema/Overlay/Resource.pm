package Test2::Harness::UI::Schema::Result::Resource;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000130';

__PACKAGE__->inflate_column(
    data => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('data', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('data', {}),
    },
);


1;
