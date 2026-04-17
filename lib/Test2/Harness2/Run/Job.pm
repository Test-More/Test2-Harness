package Test2::Harness2::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <job_id
    <test_file
    <test_file_abs
    <job_try
    <run_id
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless defined $self->{+RUN_ID};

    # Inputs can arrive in either slot with either shape -- the caller may
    # not know whether the path they have is relative or absolute. Sort by
    # shape first (absolute goes to test_file_abs, relative goes to
    # test_file) and then fill in the missing one. Resolve the absolute
    # path in the caller's current directory at construction time so a
    # later chdir does not redirect the launch.
    my @inputs = grep { defined } ($self->{+TEST_FILE}, $self->{+TEST_FILE_ABS});
    croak "'test_file' or 'test_file_abs' is required"
        unless @inputs;

    my ($abs, $rel);
    for my $path (@inputs) {
        if (File::Spec->file_name_is_absolute($path)) {
            $abs //= $path;
        }
        else {
            $rel //= $path;
        }
    }

    $abs //= File::Spec->rel2abs($rel);
    $rel //= File::Spec->abs2rel($abs);

    $self->{+TEST_FILE}     = $rel;
    $self->{+TEST_FILE_ABS} = $abs;

    $self->{+JOB_ID}  //= gen_uuid();
    $self->{+JOB_TRY} //= 0;
}

sub to_hash {
    my $self = shift;
    return {
        run_id        => $self->{+RUN_ID},
        job_id        => $self->{+JOB_ID},
        job_try       => $self->{+JOB_TRY},
        test_file     => $self->{+TEST_FILE},
        test_file_abs => $self->{+TEST_FILE_ABS},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::Job - A single test job within a run

=head1 SYNOPSIS

    use Test2::Harness2::Run::Job;

    my $job = Test2::Harness2::Run::Job->new(
        test_file => 't/foo.t',
        run_id    => $run_id,
    );

    printf "job %s: %s (try %d)\n",
        $job->job_id, $job->test_file, $job->job_try;

=head1 DESCRIPTION

A lightweight value object representing one test file to execute as part
of a L<Test2::Harness2::Run>.  The harness service creates these when a
test run is queued and uses C<job_id> to track state transitions
(pending → running → done) inside the parent L<Test2::Harness2::Run>
object.

=head1 ATTRIBUTES

=over 4

=item test_file

Relative path to the test file, kept for display. Derived from an
absolute input if the caller only supplied one.

=item test_file_abs

Absolute path to the test file, resolved in the caller's current
directory at construction time so a later chdir does not redirect the
launch. Derived from a relative input if the caller only supplied one.

At least one of L</test_file> or L</test_file_abs> is required. Each
input is classified by L<File::Spec/file_name_is_absolute>, so the
caller may hand either slot a path of either shape -- an absolute path
supplied as C<test_file> still lands in C<test_file_abs> internally,
and vice-versa.

=item run_id (required)

UUID of the parent L<Test2::Harness2::Run>.

=item job_id

UUID for this job (auto-generated if not supplied).

=item job_try

Retry counter; defaults to 0.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

See L<https://dev.perl.org/licenses/>

=cut
