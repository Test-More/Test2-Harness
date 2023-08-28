package Test2::Harness::UI::Schema::Result::Job;
use utf8;
use strict;
use warnings;

use Test2::Harness::UI::Util::ImportModes qw/record_all_events mode_check/;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000138';

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

sub file {
    my $self = shift;
    my %cols = $self->get_all_fields;

    return $cols{file}     if exists $cols{file};
    return $cols{filename} if exists $cols{filename};

    my $test_file = $self->test_file or return undef;
    return $test_file->filename;
}

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

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

sub sig {
    my $self = shift;

    return join ";" => (
        (map {$self->$_ // ''} qw/status pass_count fail_count name file fail/),
        (map {length($self->$_ // '')} qw/parameters/),
        ($self->job_fields->count),
    );
}

sub short_job_fields {
    my $self = shift;

    return [ map { my $d = +{$_->get_all_fields}; $d->{data} = $d->{has_data} ? \'1' : \'0'; $d } $self->job_fields->search(undef, {
        remove_columns => ['data'],
        '+select' => ['data IS NOT NULL AS has_data'],
        '+as' => ['has_data'],
    })->all ];
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;

    $cols{short_file}    = $self->short_file;
    $cols{shortest_file} = $self->shortest_file;

    # Inflate
    $cols{parameters} = $self->parameters;

    $cols{fields} = $self->short_job_fields;

    return \%cols;
}

my @GLANCE_FIELDS = qw{ exit_code fail fail_count job_key job_try retry name pass_count file status job_ord run_id };

sub glance_data {
    my $self = shift;
    my %cols = $self->get_all_fields;

    my %data;
    @data{@GLANCE_FIELDS} = @cols{@GLANCE_FIELDS};

    $data{file}          = $self->file;
    $data{short_file}    = $self->short_file;
    $data{shortest_file} = $self->shortest_file;

    $data{fields} = $self->short_job_fields;

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
        my $has_binary = $self->events->search({has_binary => 1});
        while (my $e = $has_binary->next()) {
            $has_binary->binaries->delete;
            $e->delete;
        }

        $self->events->delete;
        return;
    }

    my $query = {
        is_diag => 0,
        is_harness => 0,
        is_time => 0,
    };

    if (mode_check($mode, 'qvfds')) {
        $query->{'-not'} = {is_subtest => 1, nested => 0};
    }
    elsif(!mode_check($mode, 'qvfd')) {
        die "Unknown mode '$mode'";
    }

    my $has_binary = $self->events->search({%$query, has_binary => 1});
    while (my $e = $has_binary->next()) {
        $has_binary->binaries->delete;
        $e->delete;
    }

    $self->events->search($query)->delete();
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
