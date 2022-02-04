package Test2::Harness::UI::Schema::Result::Event;
use utf8;
use strict;
use warnings;

use Test2::Harness::UI::Util::ImportModes();
use Test2::Formatter::Test2::Composer();

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000108';

__PACKAGE__->parent_column('parent_id');

__PACKAGE__->inflate_column(
    facets => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('facets', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('facets', {}),
    },
);

__PACKAGE__->inflate_column(
    orphan => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('orphan', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('orphan', {}),
    },
);

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub in_mode {
    my $self = shift;
    return Test2::Harness::UI::Util::ImportModes::event_in_mode(event => $self, @_);
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Inflate
    $cols{facets} = $self->facets;
    $cols{orphan} = $self->orphan;
    $cols{lines}  = Test2::Formatter::Test2::Composer->render_super_verbose($cols{facets});

    return \%cols;
}

sub st_line_data {
    my $self = shift;

    my $out = $self->line_data;

    $out->{loading_subtest} = 1;

    return $out;
}

sub line_data {
    my $self = shift;
    my %cols = $self->get_columns;
    my %out;

    my $has_facets = ($cols{has_facets} || $cols{facets}) ? 1 : 0;
    my $has_orphan = ($cols{has_orphan} || $cols{orphan}) ? 1 : 0;

    $cols{facets} = $self->facets if $has_facets;

    $out{lines} = Test2::Formatter::Test2::Composer->render_super_verbose($has_facets ? $self->facets : $self->orphan);

    $out{facets} = $has_facets;
    $out{orphan} = $has_orphan;

    $out{parent_id} = $cols{parent_id} if $cols{parent_id};
    $out{nested}    = $cols{nested} // 0;

    $out{event_id} = $cols{event_id};

    $out{is_parent} = ($has_facets && $cols{facets}{parent}) ? 1 : 0;
    $out{is_fail}   = ($has_facets && $cols{facets}{assert}) ? $cols{facets}{assert}{pass} ? 0 : 1 : undef;

    return \%out;
}

__PACKAGE__->has_many(
    "events",
    "Test2::Harness::UI::Schema::Result::Event",
    {"foreign.parent_id" => "self.event_id"},
    {cascade_copy        => 0, cascade_delete => 0},
);

__PACKAGE__->belongs_to(
    "parent_rel",
    "Test2::Harness::UI::Schema::Result::Event",
    {event_id => "parent_id"},
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "NO ACTION",
        on_update     => "NO ACTION",
    },
);

1;

__END__

=pod

=head1 NAME

Test2::Harness::UI::Schema::Result::Event

=cut

=head1 DB STUFF

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=head2 parent_rel

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=head1 METHODS

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
