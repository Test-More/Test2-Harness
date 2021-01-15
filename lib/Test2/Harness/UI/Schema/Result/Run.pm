package Test2::Harness::UI::Schema::Result::Run;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;

our $VERSION = '0.000029';

BEGIN {
    confess "You must first load a Test2::Harness::UI::Schema::NAME module"
        unless $Test2::Harness::UI::Schema::LOADED;

    if ($Test2::Harness::UI::Schema::LOADED =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        *DTF = sub() { 'DateTime::Format::Pg' };
    }
    elsif ($Test2::Harness::UI::Schema::LOADED =~ m/mysql/i) {
        require DateTime::Format::MySQL;
        *DTF = sub() { 'DateTime::Format::MySQL' };
    }
    else {
        die "Not sure what DateTime::Formatter to use";
    }
}

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

__PACKAGE__->inflate_column(
    fields => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('fields', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('fields', {}),
    },
);

sub complete {
    my $self = shift;

    my $status = $self->status;

    return 1 if $status eq 'complete';
    return 1 if $status eq 'failed';
    return 0;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Just No.
    delete $cols{log_data};

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{fields} = $self->fields;

    $cols{user} = $self->user->username;
    $cols{project} = $self->project->name;

    my $dt = DTF()->parse_datetime( $cols{added} );

    # Convert from UTC to localtime
    $dt->set_time_zone('UTC');
    $dt->set_time_zone('local');

    $cols{added} = $dt->strftime("%Y-%m-%d %I:%M%P");

    return \%cols;
}

1;

__END__

=pod

=head1 NAME

Test2::Harness::UI::Schema::Result::Run

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
