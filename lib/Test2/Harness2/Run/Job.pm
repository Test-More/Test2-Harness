package Test2::Harness2::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::TestFile;

use Object::HashBase qw{
    <job_id
    <test_file
    <job_try
    <run_id
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless defined $self->{+RUN_ID};

    my $tf = $self->{+TEST_FILE};
    croak "'test_file' is a required attribute" unless defined $tf;

    # Accept either a TestFile instance or a bare path (string) for
    # convenience. Anything else is a bug on the caller's side.
    if (blessed($tf)) {
        croak "'test_file' must be a Test2::Harness2::TestFile, got a " . ref($tf)
            unless $tf->isa('Test2::Harness2::TestFile');
    }
    elsif (ref($tf)) {
        croak "'test_file' must be a Test2::Harness2::TestFile or a path string";
    }
    else {
        $self->{+TEST_FILE} = Test2::Harness2::TestFile->new(file => $tf);
    }

    $self->{+JOB_ID}  //= gen_uuid();
    $self->{+JOB_TRY} //= 0;
}

sub test_file_abs { $_[0]->{+TEST_FILE}->file }
sub test_file_rel { $_[0]->{+TEST_FILE}->relative }

sub TO_JSON { return {%{$_[0]}} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::Job - A single test job within a run

=head1 SYNOPSIS

    use Test2::Harness2::Run::Job;
    use Test2::Harness2::TestFile;

    my $job = Test2::Harness2::Run::Job->new(
        test_file => Test2::Harness2::TestFile->new(file => 't/foo.t'),
        run_id    => $run_id,
    );

    # Convenience: path strings are wrapped in a default TestFile.
    my $job2 = Test2::Harness2::Run::Job->new(
        test_file => 't/foo.t',
        run_id    => $run_id,
    );

    printf "job %s: %s (try %d)\n",
        $job->job_id, $job->test_file_rel, $job->job_try;

=head1 DESCRIPTION

A lightweight value object representing one test file to execute as part
of a L<Test2::Harness2::Run>. The harness service creates these when a
test run is queued and uses C<job_id> to track state transitions
(pending → running → done) inside the parent L<Test2::Harness2::Run>
object.

=head1 ATTRIBUTES

=over 4

=item test_file (required)

A L<Test2::Harness2::TestFile>. A plain path string is accepted as a
convenience and will be wrapped in a default C<TestFile> automatically.

=item run_id (required)

UUID of the parent L<Test2::Harness2::Run>.

=item job_id

UUID for this job (auto-generated if not supplied).

=item job_try

Retry counter; defaults to 0.

=back

=head1 METHODS

=over 4

=item $path = $job->test_file_abs

Absolute path of the test file, equivalent to C<< $job->test_file->file >>.

=item $path = $job->test_file_rel

Relative path, equivalent to C<< $job->test_file->relative >>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
