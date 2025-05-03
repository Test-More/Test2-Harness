package App::Yath::Theme;
use strict;
use warnings;

use Getopt::Yath::Term qw/color/;
use List::Util qw/shuffle/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    use_color
    _job_color_instances
    color_map_text
    color_map_term
    borders
};

# Return key value pairs
sub DEFAULT_BASE_COLORS()   { (reset => 'reset') }
sub DEFAULT_STATE_COLORS()  { () }
sub DEFAULT_STATUS_COLORS() { () }
sub DEFAULT_TAG_COLORS()    { () }
sub DEFAULT_FACET_COLORS()  { () }

# Return a list
sub DEFAULT_JOB_COLORS() { ('black on_white') }

# Return key value pairs
sub DEFAULT_BORDERS { ('default' => ['[', ']']) }

sub color_vals {
    my $self = shift;
    my ($pairs) = @_;
    $pairs->{$_} = color($pairs->{$_}) for keys %$pairs;
    return $pairs;
}

sub init {
    my $self = shift;

    $self->{+BORDERS} //= {$self->DEFAULT_BORDERS};

    $self->{+USE_COLOR} //= -t STDOUT;

    return unless $self->{+USE_COLOR};

    $self->{+_JOB_COLOR_INSTANCES} //= {};

    $self->{+COLOR_MAP_TEXT} //= {
        base   => {$self->DEFAULT_BASE_COLORS()},
        tag    => {$self->DEFAULT_TAG_COLORS()},
        facet  => {$self->DEFAULT_FACET_COLORS()},
        status => {$self->DEFAULT_STATUS_COLORS()},
        state  => {$self->DEFAULT_STATE_COLORS()},
        job    => {},
    };

    $self->{+COLOR_MAP_TERM} //= {
        base   => $self->color_vals({$self->DEFAULT_BASE_COLORS()}),
        tag    => $self->color_vals({$self->DEFAULT_TAG_COLORS()}),
        facet  => $self->color_vals({$self->DEFAULT_FACET_COLORS()}),
        status => $self->color_vals({$self->DEFAULT_STATUS_COLORS()}),
        state  => $self->color_vals({$self->DEFAULT_STATE_COLORS()}),
        job    => {},
    };
}

# Mainly for terminals, tag/facet border shapes
sub get_borders {
    my $self = shift;
    my ($name) = @_;

    return $self->{+BORDERS}->{$name} // $self->{+BORDERS}->{default} // [' ', ' '];
}

# Get the color code for colorizing terminal text
sub get_term_color {
    my $self = shift;
    $self->_get_color($self->{+COLOR_MAP_TERM}, @_);
}

# Get the human readable color name
sub get_text_color {
    my $self = shift;
    $self->_get_color($self->{+COLOR_MAP_TEXT}, @_);
}

my %GENERATOR = ( job => 'assign_job_color' );

sub _get_color {
    my $self = shift;
    my ($map, $thing, $name) = @_;

    return '' unless $self->{+USE_COLOR};

    # Note, this is intentionally allowing ->get_term_color('reset') to shortcut getting base => reset
    $thing = lc($thing);
    my $set = $map->{$thing} // return $map->{base}->{reset} // '';

    $name = lc($name);
    return $set->{$name} if $set->{$name};

    my $gen = $GENERATOR{$thing} or return $map->{base}->{reset} // '';
    $self->$gen($name);

    return $set->{$name} //= $map->{base}->{reset} // '';
}

sub assign_job_color {
    my $self = shift;
    my ($id) = @_;

    return '' unless $self->{+USE_COLOR};

    my ($it, $count);
    for my $color (shuffle($self->DEFAULT_JOB_COLORS())) {
        my $c = $self->{+_JOB_COLOR_INSTANCES} //= 0;

        # If count is 0 we can use it now.
        if ($c == 0) {
            $it = $color;
            last;
        }

        # If we do not have any selection, or if this color is used less than the current selection, set the selection
        if (!$count || $count > $c) {
            $count = $c;
            $it = $color;
        }
    }

    # We now either have an unused color, or one of the leats used colors.
    $self->{+_JOB_COLOR_INSTANCES}->{$it}++; # Note another use of the color

    $self->{+COLOR_MAP_TEXT}->{job}->{$id} = $it;
    eval { $self->{+COLOR_MAP_TERM}->{job}->{$id} = color($it); 1 } or die "XXX: '$it': $@";

    return;
}

sub free_job_color {
    my $self = shift;
    my ($id) = @_;

    $id = lc($id);

    delete $self->{+COLOR_MAP_TERM}->{job}->{$id};
    my $c = delete $self->{+COLOR_MAP_TEXT}->{job}->{$id};

    $self->{+_JOB_COLOR_INSTANCES}->{$c}-- if $c;

    return;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Theme - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

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


=pod

=cut POD NEEDS AUDIT

