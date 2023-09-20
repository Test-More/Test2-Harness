package Test2::Harness::UI::Schema::Result::RunField;
use utf8;
use strict;
use warnings;

use Test2::Harness::Util::JSON qw/decode_json/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000142';

__PACKAGE__->inflate_column(
    data => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('data', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('data', {}),
    },
);

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
    $cols{data} = decode_json($cols{data}) if $cols{data} && !ref($cols{data});
    return \%cols;
}

1;
