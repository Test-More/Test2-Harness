package Test2::Harness2::Collector::Logger::JSON;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/parse_exit/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use Object::HashBase qw{
    <output_file
    <spec
    <ipcm_info
    +auditor
    +_data
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    croak "'output_file' is a required attribute"
        unless defined $self->{+OUTPUT_FILE};

    # spec is optional: when present it gets serialized at startup so
    # the sidecar has identity data; when absent the sidecar carries
    # only exit status and (if an auditor is attached) the pass/fail
    # verdict recorded at shutdown.
    if (defined $self->{+SPEC}) {
        croak "'spec' must be an object that implements TO_JSON"
            unless blessed($self->{+SPEC}) && $self->{+SPEC}->can('TO_JSON');
    }
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

sub set_auditor {
    my ($self, $auditor) = @_;
    $self->{+AUDITOR} = $auditor;
    return;
}

# Nothing to stream: the whole job of this logger is one snapshot at start
# and one atomic-swap at shutdown.
sub log_events { 0 }

# The .json file is the retrievable product; let downstream consumers know
# where to read it.
sub metadata {
    my $self = shift;
    return {json_file => $self->{+OUTPUT_FILE}};
}

# Take a snapshot of the spec at startup so shutdown can publish the
# original data plus exit/pass details regardless of any mutation the
# spec underwent during collection. When no spec was supplied we skip
# the initial snapshot; shutdown will still publish exit/pass.
sub startup {
    my $self = shift;

    return unless defined $self->{+SPEC};

    my $data = $self->{+SPEC}->TO_JSON;
    $self->{+_DATA} = $data;

    write_json_file_atomic($self->{+OUTPUT_FILE}, $data);
}

# At shutdown, overwrite the file with the original startup data plus the
# collected process's exit status and (when an auditor is attached) the
# auditor's pass/fail verdict. When no spec and no cached data are
# available, start from an empty hash.
sub shutdown {
    my $self = shift;
    my ($collector) = @_;

    my $base =
          defined $self->{+_DATA} ? $self->{+_DATA}
        : defined $self->{+SPEC}  ? $self->{+SPEC}->TO_JSON
        :                           {};
    my $data = {%$base};

    if (blessed($collector) && $collector->can('child_exit')) {
        my $raw = $collector->child_exit;
        $data->{exit} = parse_exit($raw) if defined $raw;
    }

    if (my $auditor = $self->{+AUDITOR}) {
        $data->{pass} = $auditor->pass ? 1 : 0;
    }

    write_json_file_atomic($self->{+OUTPUT_FILE}, $data);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::JSON - Snapshot-style JSON sidecar logger.

=head1 DESCRIPTION

A collector logger that captures a one-shot snapshot of whatever it is
collecting and drops it into a C<.json> file next to the streaming log.

Unlike L<Test2::Harness2::Collector::Logger::JSONL>, this logger does not
process per-event callbacks.  It acts only at lifecycle boundaries:

=over 4

=item startup

Serialize C<< $spec->TO_JSON >> and write it atomically to C<output_file>.

=item shutdown

Re-publish the same data with two additions: the collected process's
wait-status parsed via L<Test2::Harness2::Util/parse_exit> (as C<exit>),
and -- when an auditor is attached -- the auditor's boolean verdict (as
C<pass>, C<1> for passing, C<0> for failing).  The file is replaced via
an atomic C<rename> so readers never see a partial write.

=back

Typical use is alongside a JSONL event logger: consumers of the workdir
see a C<.json> sidecar describing I<what> is being collected (the test
job, the harness service, ...) and a C<.jsonl> file streaming I<what
happened>.  The JSON sidecar's shutdown write closes the loop with the
exit status and pass/fail verdict.

=head1 SYNOPSIS

    Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        loggers => [
            [
                'Test2::Harness2::Collector::Logger::JSONL',
                output_file => "$workdir/runs/$run_id/$job_id/0.jsonl",
            ],
            [
                'Test2::Harness2::Collector::Logger::JSON',
                output_file => "$workdir/runs/$run_id/$job_id/0.json",
                spec        => $job,
            ],
        ],
    );

=head1 ATTRIBUTES

=over 4

=item ipcm_info (required)

IPC::Manager route info, forwarded from the collector.  Not used by this
logger itself but required by the role contract so blessed instances
receive it consistently.

=item output_file (required)

Path to the C<.json> file to create.  The logger writes a sibling
tempfile in the same directory and C<rename>s it over this path.

=item spec (required)

The object to serialize at startup (and re-serialize at shutdown).  Must
implement a C<TO_JSON> method returning a plain hashref.  For a test job
collector this is a L<Test2::Harness2::Run::Job>; for the harness
service's own interpose collector this is the L<Test2::Harness2>
instance itself.

=back

=head1 METADATA

L</metadata> returns C<< { json_file => $output_file } >> so the
C<job_loggers> event the harness service publishes includes a locator
for the sidecar.

=head1 SEE ALSO

L<Test2::Harness2::Collector::Logger::JSONL> -- streaming-event sibling.

L<Test2::Harness2::Role::Collector::Logger> -- role contract.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
