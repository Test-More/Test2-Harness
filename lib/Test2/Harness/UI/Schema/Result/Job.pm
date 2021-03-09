package Test2::Harness::UI::Schema::Result::Job;
use utf8;
use strict;
use warnings;

use Test2::Harness::UI::Util::ImportModes qw/record_all_events mode_check/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000040';

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

sub shortest_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{([^/]+)$};
    return $file;
}

sub short_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{/(t2?/.*)$}i;
    return $1 if $file =~ m{([^/\\]+\.(?:t2?|pl))$}i;
    return $file;
}

sub complete {
    my $self = shift;

    my $status = $self->status;

    return 1 if $status eq 'complete';
    return 1 if $status eq 'failed';
    return 1 if $status eq 'canceled';
    return 1 if $status eq 'broken';
    return 0;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    $cols{short_file}    = $self->short_file;
    $cols{shortest_file} = $self->shortest_file;

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{fields}     = $self->fields;

    return \%cols;
}

my @GLANCE_FIELDS = qw{ exit_code fail fail_count job_key job_try retry name pass_count file status job_ord };

sub glance_data {
    my $self = shift;
    my %cols = $self->get_columns;

    my %data;
    @data{@GLANCE_FIELDS} = @cols{@GLANCE_FIELDS};

    $data{short_file}    = $self->short_file;
    $data{shortest_file} = $self->shortest_file;

    # Inflate
    if ($data{fields} = $self->fields) {
        $_->{data} = !!$_->{data} for @{$data{fields}};
    }

    return \%data;
}

sub normalize_to_mode {
    my $self = shift;
    my %params = @_;

    my $mode = $params{mode} // $self->run->mode;

    # No need to purge anything
    return if record_all_events(mode => $mode, job => $self);
    return if mode_check($mode, 'complete');

    if (mode_check($mode, 'summary', 'qvf')) {
        $self->events->delete_all;
        return;
    }

    die "Unknown mode '$mode'" unless mode_check($mode, 'qvfd');

    $self->events->search({is_diag => 0, is_harness => 0, is_time => 0})->delete_all();
}

1;

__END__

=pod

=head1 NAME

Test2::Harness::UI::Schema::Result::Job

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
