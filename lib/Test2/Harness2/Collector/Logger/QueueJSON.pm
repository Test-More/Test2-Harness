package Test2::Harness2::Collector::Logger::QueueJSON;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <workdir
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

# Only meaningful in a 'service'-kind collector: the run_queued / test_start
# events this logger cares about are emitted by the harness service, not by
# test processes. A test-kind collector would never see them, so we drop the
# spec there instead of silently writing empty files.
sub applicable {
    my ($class, $info) = @_;
    my $kind = $info && $info->{kind};
    return 1 if !defined $kind;
    return $kind eq 'service' ? 1 : 0;
}

sub init {
    my $self = shift;

    croak "'workdir' is a required attribute"
        unless defined $self->{+WORKDIR};
}

sub log_event {
    my $self = shift;
    my ($event) = @_;

    my $harness = $event->facet_data->{harness} or return;
    my $kind    = $harness->{kind}              or return;

    return $self->_write_run_snapshot($harness) if $kind eq 'run_queued';
    return $self->_write_job_snapshot($harness) if $kind eq 'test_start';

    return;
}

sub _write_run_snapshot {
    my $self = shift;
    my ($harness) = @_;

    my $run    = $harness->{run} or return;
    my $run_id = $run->{run_id};
    return unless defined $run_id;

    my $dir = "$self->{+WORKDIR}/runs";
    make_path($dir) unless -d $dir;

    $self->_write_json("$dir/$run_id.json", $run);

    return;
}

sub _write_job_snapshot {
    my $self = shift;
    my ($harness) = @_;

    my $job    = $harness->{job}                      or return;
    my $run_id = $job->{run_id} // $harness->{run_id} or return;
    my $job_id = $job->{job_id} // $harness->{job_id} or return;

    my $dir = "$self->{+WORKDIR}/runs/$run_id";
    make_path($dir) unless -d $dir;

    $self->_write_json("$dir/$job_id.json", $job);

    return;
}

sub _write_json {
    my $self = shift;
    my ($path, $data) = @_;

    open(my $fh, '>', $path)
        or croak "Could not open '$path': $!";
    print $fh encode_json($data), "\n";
    close($fh)
        or croak "Could not close '$path': $!";

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::QueueJSON - Per-run / per-job JSON
snapshot logger.

=head1 DESCRIPTION

Writes two kinds of JSON snapshot files under C<< $workdir/runs/ >> as the
harness service emits queue-lifecycle events:

=over 4

=item C<$workdir/runs/$run_id.json>

Written on C<run_queued>. Contains the full flattened run structure
(C<run_id>, C<created_at>, C<jobs>, C<pending>, C<running>, C<done>) so
downstream tooling can inspect the original queue contents without having
to replay per-job event logs.

=item C<$workdir/runs/$run_id/$job_id.json>

Written on C<test_start>. Contains the flattened job structure
(C<run_id>, C<job_id>, C<job_try>, C<test_file>, C<test_file_abs>) for
each test as it starts.

=back

The logger only applies in C<'service'>-kind collector contexts -- the
C<applicable()> guard drops it from test-kind collectors, where these
events never appear.

All other events (including plain stdout/stderr from the service itself)
are ignored.

=head1 ATTRIBUTES

=over 4

=item workdir (required)

The base directory that the C<runs/> tree lives under. When used as the
service's logger inside L<Test2::Harness2>, C<workdir> is plumbed in
automatically.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
