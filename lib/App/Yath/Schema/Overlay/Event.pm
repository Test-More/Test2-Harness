package App::Yath::Schema::Overlay::Event;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Event;
use utf8;
use strict;
use warnings;

use App::Yath::Schema::ImportModes();
use App::Yath::Renderer::Default::Composer();

use Carp qw/confess/;
confess "You must first load a App::Yath::Schema::NAME module"
    unless $App::Yath::Schema::LOADED;

__PACKAGE__->parent_column('parent_id');

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub facets { shift->facet }

sub in_mode {
    my $self = shift;
    return App::Yath::Schema::ImportModes::event_in_mode(event => $self, @_);
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
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
    my %cols = $self->get_all_fields;
    my %out;

    my $has_facets = $cols{has_facets} ? 1 : 0;
    my $has_orphan = $cols{has_orphan} ? 1 : 0;
    my $has_binary = $cols{has_binary} ? 1 : 0;
    my $is_parent  = $cols{is_subtest} ? 1 : 0;
    my $causes_fail = $cols{causes_fail} ? 1 : 0;

    $out{lines} = [map { [$_->facet, $_->real_tag, $_->message, $_->data] } $self->renders];

    if ($has_binary) {
        for my $binary ($self->binaries) {
            my $filename = $binary->filename;

            push @{$out{lines}} => [
                'binary',
                $binary->is_image ? 'IMAGE' : 'BINARY',
                $filename,
                $binary->binary_idx,
            ];
        }
    }

    $out{facets}    = $has_facets;
    $out{orphan}    = $has_orphan;
    $out{is_parent} = $is_parent;
    $out{is_fail}   = $causes_fail;

    $out{parent_id} = $cols{parent_id} if $cols{parent_id};
    $out{nested}    = $cols{nested} // 0;

    $out{event_id} = $cols{event_id};

    return \%out;
}

__PACKAGE__->has_many(
    "events",
    "App::Yath::Schema::Result::Event",
    {"foreign.parent_id" => "self.event_id"},
    {cascade_copy        => 0, cascade_delete => 0},
);

__PACKAGE__->belongs_to(
    "parent_rel",
    "App::Yath::Schema::Result::Event",
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

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Result::Event - Overlay for Event result class.

=head1 DESCRIPTION

This is where custom (not autogenerated) code for the Event result class lives.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut
