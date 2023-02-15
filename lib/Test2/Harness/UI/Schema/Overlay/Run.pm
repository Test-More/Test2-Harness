package Test2::Harness::UI::Schema::Result::Run;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;

our $VERSION = '0.000130';

use Test2::Harness::UI::Util::DateTimeFormat qw/DTF/;

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

# For joining
__PACKAGE__->belongs_to(
  "user_join",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

sub sig {
    my $self = shift;

    return join ";" => (
        (map {$self->$_ // ''} qw/status pinned passed failed retried concurrency/),
        (map {length($self->$_ // '')} qw/parameters/),
        ($self->run_fields->count),
    );
}

sub short_run_fields {
    my $self = shift;

    return [ map { my $d = +{$_->get_columns}; $d->{data} = $d->{data} ? \'1' : \'0'; $d } $self->run_fields->search(undef, {
        remove_columns => ['data'],
        '+select' => ['data IS NOT NULL AS data'],
        '+as' => ['data'],
    })->all ];
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Just No.
    delete $cols{log_data};

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{user}       //= $self->user->username;
    $cols{project}    //= $self->project->name;

    if ($cols{prefetched_fields}) {
        $cols{fields} = [ map { {$_->get_columns} } $self->run_fields ];
    }
    else {
        $cols{fields} = $self->short_run_fields;
    }

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

sub expanded_coverages {
    my $self = shift;
    my ($query) = @_;

    my $pick_me = {run_id => $self->run_id};

    if ($query) {
        $query = {'-and' => [$query, $pick_me]};
    }
    else {
        $query = $pick_me;
    }

    my $schema = $self->result_source->schema;
    $schema->resultset('Coverage')->search(
        $query,
        {
            order_by   => [qw/test_file_id source_file_id source_sub_id/],
            join       => [qw/test_file source_file source_sub coverage_manager/],
            '+columns' => {
                test_file   => 'test_file.filename',
                source_file => 'source_file.filename',
                source_sub  => 'source_sub.subname',
                manager     => 'coverage_manager.package',
            },
        },
    );
}

sub coverage_data {
    my $self = shift;
    my (%params) = @_;

    my $query = $params{query};
    my $rs = $self->expanded_coverages($query);

    my $curr_test;
    my $data;
    my $end = 0;

    my $run_id;
    my $iterator = sub {
        while (1) {
            return undef if $end;

            my $out;

            my $item = $rs->next;
            if (!$item) {
                $end  = 1;
                $out  = $data;
                $data = undef;
                return $out;
            }

            $run_id //= $item->run_id;
            die "Different run id!" if $run_id ne $item->run_id;

            my $fields = $item->human_fields;
            my $test   = $fields->{test_file};
            if (!$curr_test || $curr_test ne $test) {
                $out  = $data;
                $data = undef;

                $curr_test = $test;

                $data = {
                    test       => $test,
                    aggregator => 'Test2::Harness::Log::CoverageAggregator::ByTest',
                    files      => {},
                };

                $data->{manager} = $fields->{manager} if $fields->{manager};
            }

            my $source = $fields->{source_file};
            my $sub    = $fields->{source_sub};
            my $meta   = $fields->{metadata};

            $data->{files}->{$source}->{$sub} = $meta;

            return $out if $out;
        }
    };

    return $iterator if $params{iterator};

    my @out;
    while (my $item = $iterator->()) {
        push @out => $item;
    }

    return @out;
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
