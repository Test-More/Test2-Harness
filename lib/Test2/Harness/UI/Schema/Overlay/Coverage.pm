package Test2::Harness::UI::Schema::Result::Coverage;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000112';

__PACKAGE__->inflate_column(
    metadata => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('metadata', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('metadata', {}),
    },
);

sub human_fields {
    my $self = shift;

    my %cols = $self->get_columns;

    $cols{test_file}   //= $self->test_filename;
    $cols{source_file} //= $self->source_filename;
    $cols{source_sub}  //= $self->source_subname;
    $cols{manager}     //= $self->manager_package;

    $cols{metadata} = $self->metadata // ['*'];

    return {map { $_ => $cols{$_} } qw/test_file source_file source_sub manager metadata/};
}

sub test_filename {
    my $self = shift;
    my %cols = $self->get_columns;

    return $cols{test_file} // $self->test_file->filename;
}

sub source_filename {
    my $self = shift;
    my %cols = $self->get_columns;

    return $cols{source_file} // $self->source_file->filename;
}

sub source_subname {
    my $self = shift;
    my %cols = $self->get_columns;

    return $cols{source_sub} // $self->source_sub->subname;
}

sub manager_package {
    my $self = shift;
    my %cols = $self->get_columns;

    return $cols{manager} if $cols{manager};
    my $manager = $self->coverage_manager or return undef;
    return $manager->package;
}

1;
