package Test2::Harness2::Run;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase qw{
    <run_uuid
    <run_ord
    <jobs
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run - A queued run: an identity plus its jobs.

=head1 DESCRIPTION

A value object representing one queued run. For now a run is just its identity
(C<run_uuid> / C<run_ord>) and the list of L<Test2::Harness2::Run::Job> objects
it owns -- one per test file. The jobs are handed in already in their final
form; the run does not build, scan, or classify them.

=head1 SYNOPSIS

    use Test2::Harness2::Run;

    my $run = Test2::Harness2::Run->new(
        run_uuid => $uuid,
        run_ord  => 1,
    );

    $run->add_job($job);

    for my $job (@{$run->jobs}) { ... }

=head1 ATTRIBUTES

=over 4

=item run_uuid (required)

UUID for the run.

=item run_ord (required)

Numeric order the run was queued in, starting at 1.

=item jobs

Arrayref of L<Test2::Harness2::Run::Job> objects, in job order. Defaults to an
empty arrayref.

=back

=cut

sub init ($self) {
    croak "'run_uuid' is a required attribute" unless defined $self->{+RUN_UUID} && length $self->{+RUN_UUID};
    croak "'run_ord' is a required attribute"  unless defined $self->{+RUN_ORD};

    $self->{+JOBS} //= [];

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $job = $run->add_job($job)

Append a L<Test2::Harness2::Run::Job> to the run. Returns the job.

=item $arrayref = $run->job_uuids

The C<job_uuid> of every job, in order.

=back

=cut

sub add_job ($self, $job) {
    push @{$self->{+JOBS}} => $job;
    return $job;
}

sub job_uuids ($self) {
    return [map { $_->job_uuid } @{$self->{+JOBS}}];
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
