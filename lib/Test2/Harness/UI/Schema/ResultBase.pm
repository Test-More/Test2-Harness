package Test2::Harness::UI::Schema::ResultBase;
use strict;
use warnings;

use base 'DBIx::Class::Core';

sub get_all_fields {
    my $self = shift;
    my @fields = $self->result_source->columns;
    return ( map {($_ => $self->$_)} @fields );
}

1;
