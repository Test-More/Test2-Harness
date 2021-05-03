package Test2::Harness::UI::Schema::Result::Run;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;

our $VERSION = '0.000064';

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

__PACKAGE__->inflate_column(
    coverage => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('fields', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('fields', {}),
    },
);

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

sub sig {
    my $self = shift;

    return join ";" => (
        (map {$self->$_ // ''} qw/status pinned passed failed retried concurrency/),
        (map {length($self->$_ // '')} qw/fields parameters/),
    );
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Just No.
    delete $cols{log_data};

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{fields}     = $self->fields;

    $cols{coverage} = $cols{coverage} ? 1 : 0;

    $cols{user} = $self->user->username;
    $cols{project} = $self->project->name;

    my $dt = DTF()->parse_datetime( $cols{added} );

    $cols{added} = $dt->strftime("%Y-%m-%d %I:%M%P");

    return \%cols;
}

sub normalize_to_mode {
    my $self = shift;
    my %params = @_;

    my $mode = $params{mode};

    if ($mode) {
        $self->update({mode => $mode});
    }
    else {
        $mode = $self->mode;
    }

    $_->normalize_to_mode(mode => $mode) for $self->jobs->all;
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
