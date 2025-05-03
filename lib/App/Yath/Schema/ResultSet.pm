package App::Yath::Schema::ResultSet;
use strict;
use warnings;

our $VERSION = '2.000005';

use parent 'DBIx::Class::ResultSet';

use Carp qw/croak/;
use Test2::Util::UUID qw/looks_like_uuid/;
use App::Yath::Schema::Util qw/format_uuid_for_db/;

__PACKAGE__->load_components('Helper::ResultSet::RemoveColumns');

sub find_by_id_or_uuid {
    my $self = shift;
    my ($id, $query, $attrs) = @_;

    $query //= {};
    $attrs //= {};

    my $rs = $self->result_source;

    my ($pcol, @extra) = $rs->primary_columns;
    croak "find_by_id_or_uuid() cannot be used on this class as it has more than one primary key column" if @extra;

    my $ucol;
    if ($pcol =~ m/^(.+)_id$/) {
        $ucol = "${1}_uuid";
        croak "find_by_id_or_uuid() cannot be used on this class as it ha sno '$ucol' column"
            unless $rs->has_column($ucol);
    }
    else {
        croak "Not sure how to turn '$pcol' into the uuid column";
    }

    if (looks_like_uuid($id)) {
        $query->{$ucol} = format_uuid_for_db($id);
    }
    elsif ($id =~ m/^\d+$/) {
        $query->{$pcol} = $id;
    }
    else {
        croak "'$id' does not look like either a numeric ID or a UUID";
    }

    return $self->find($query, $attrs);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::ResultSet - Common resultset class for yath.

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

