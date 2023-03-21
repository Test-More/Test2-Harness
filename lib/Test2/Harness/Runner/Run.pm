package Test2::Harness::Runner::Run;
use strict;
use warnings;

our $VERSION = '1.000152';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness::Util::File::JSONL;

use parent 'Test2::Harness::Run';
use Test2::Harness::Util::HashBase qw{
    <workdir
    <state
    <run_id

    +run_dir
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};
    croak "'state' is a required attribute"   unless $self->{+STATE};
    croak "'run_id' is a required attribute"  unless $self->{+RUN_ID};
}

sub run_dir { $_[0]->{+RUN_DIR} //= $_[0]->SUPER::run_dir($_[0]->{+WORKDIR}) }

sub jobs {
    my $self = shift;
    my $data = $self->state->data->queue->{$self->{+RUN_ID}} or return [];
    return $data->{list};
}

sub add_job {
    my $self = shift;
    my ($job, $spawn_time) = @_;

    my $json_data = $job->TO_JSON();
    $json_data->{stamp} = $spawn_time;

    $self->state->transaction(w => sub {
        my ($state, $data) = @_;
        my $jobs = $data->jobs->{$self->{+RUN_ID}} //= {
            closed => 0,
            list => [],
        };

        push @{$jobs->{list}} => $json_data,
    });

    return $json_data;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Run - Runner specific subclass of a test run.

=head1 DESCRIPTION

Runner subclass of L<Test2::Harness::Run> for use inside the runner.

=head1 METHODS

In addition to the methods provided by L<Test2::Harness::Run>, these are provided.

=over 4

=item $dir = $run->workdir

Runner directory.

=item $dir = $run->run_dir

Directory specific to this run.

=item $path = $run->jobs_file

Path to the C<jobs.jsonl> file.

=item $fh = $run->jobs

Filehandle to C<jobs.jsonl>.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
