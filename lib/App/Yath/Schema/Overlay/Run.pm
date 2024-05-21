package App::Yath::Schema::Overlay::Run;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Run;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;

use App::Yath::Schema::DateTimeFormat qw/DTF/;

# For joining
__PACKAGE__->belongs_to(
  "user_join",
  "App::Yath::Schema::Result::User",
  { user_idx => "user_idx" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

if ($App::Yath::Schema::LOADED eq 'Percona') {
    __PACKAGE__->might_have(
      "run_parameter",
      "App::Yath::Schema::Result::RunParameter",
      { "foreign.run_id" => "self.run_id" },
      { cascade_copy => 0, cascade_delete => 1 },
    );
}

my %COMPLETE_STATUS = (complete => 1, failed => 1, canceled => 1, broken => 1);
sub complete { return $COMPLETE_STATUS{$_[0]->status} // 0 }

sub sig {
    my $self = shift;

    my $run_parameter = $self->run_parameter;

    return join ";" => (
        (map {$self->$_ // ''} qw/status pinned passed failed retried concurrency/),
        $run_parameter ? length($run_parameter->parameters) : (''),
        ($self->run_fields->count),
    );
}

sub short_run_fields {
    my $self = shift;

    return $self->run_fields->search(undef, {
        remove_columns => ['data'],
        '+select' => ['data IS NOT NULL AS has_data'],
        '+as' => ['has_data'],
    })->all;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;

    # Inflate
    if (my $p = $self->run_parameter) {
        $cols{parameters} = $p->parameters;
    }

    $cols{user}       //= $self->user->username;
    $cols{project}    //= $self->project->name;

    $cols{fields} = [];
    for my $rf ($cols{prefetched_fields} ? $self->run_fields : $self->short_run_fields) {
        my $fields = {$rf->get_all_fields};

        my $has_data = delete $fields->{data};
        $fields->{has_data} //= $has_data ? \'1' : \'0';

        push @{$cols{fields}} => $fields;
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

    $self->coverages->search(
        $query,
        {
            order_by   => [qw/test_file_idx source_file_idx source_sub_idx/],
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

sub rerun_data {
    my $self = shift;

    my $files = $self->jobs->search(
        {},
        {join => 'test_file', order_by => 'test_file.filename'},
    );

    my $data = {};

    while (my $file = $files->next) {
        my $name = $file->file || next;

        my $row = $data->{$name} //= {};

        $row->{retry}++ if $file->job_try > 0;

        if($file->ended) {
            $row->{end}++;
            $row->{$file->fail ? 'fail' : 'pass'}++;
        }
    }

    return $data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Result::Run - Overlay for Run result class.

=head1 DESCRIPTION

This is where custom (not autogenerated) code for the Run result class lives.

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
