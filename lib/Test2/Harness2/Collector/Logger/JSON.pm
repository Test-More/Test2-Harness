package Test2::Harness2::Collector::Logger::JSON;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/parse_exit/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;
use Test2::Harness2::Util::File::JSON;

use Object::HashBase qw{
    <output_file
    <spec
    <logdir
    <service_name
    <run_id
    <job_id
    <job_try
    <is_run
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

    # spec is entirely optional now: the logger either consumes
    # run_mutation events (the run-service snapshot stream) or falls
    # back to a spec->TO_JSON shot at startup / shutdown. Both are
    # valid ways to feed the sidecar.
    if (defined $self->{+SPEC}) {
        croak "'spec' must be an object that implements TO_JSON"
            unless blessed($self->{+SPEC}) && $self->{+SPEC}->can('TO_JSON');
    }
}

sub output_files {
    my $self = shift;
    $self->{+OUTPUT_FILE} //= $self->output_file_basename . '.json';
    return ($self->{+OUTPUT_FILE});
}

sub set_process_info {
    my ($self, %info) = @_;
    $self->{+LOGDIR}       = $info{logdir}       if exists $info{logdir};
    $self->{+SERVICE_NAME} = $info{service_name} if exists $info{service_name};
    $self->{+RUN_ID}       = $info{run_id}       if exists $info{run_id};
    $self->{+JOB_ID}       = $info{job_id}       if exists $info{job_id};
    $self->{+JOB_TRY}      = $info{job_try}      if exists $info{job_try};
    $self->{+IS_RUN}       = $info{is_run}       if exists $info{is_run};
    return;
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

# Event stream is now the source of truth when we're running under a
# run service: every run_mutation event carries the authoritative Run
# snapshot and we cache whichever was most recent. If nothing with a
# run_data payload comes through the event stream, the shutdown path
# falls back to spec->TO_JSON.
sub log_events { 1 }

sub log_event {
    my ($self, $event) = @_;

    my $fd = $event->facet_data or return;
    my $h  = $fd->{harness}     or return;

    return unless defined $h->{kind} && $h->{kind} eq 'run_mutation';
    my $run_data = $h->{run_data};
    return unless ref($run_data) eq 'HASH';

    $self->{+_DATA} = {%$run_data};
    return;
}

sub metadata {
    my $self = shift;
    return {json_file => $self->{+OUTPUT_FILE}};
}

# Startup snapshot: write whatever we already have (spec->TO_JSON if
# a spec was supplied, otherwise an empty stub) so downstream readers
# see a file from the very first moment. run_mutation events will
# overwrite it as they arrive; shutdown cements the final state.
sub startup {
    my $self = shift;

    $self->output_files unless defined $self->{+OUTPUT_FILE};

    my $data = defined $self->{+SPEC} ? $self->{+SPEC}->TO_JSON : {};
    $self->{+_DATA} = $data;

    write_json_file_atomic($self->{+OUTPUT_FILE}, $data);
}

sub shutdown {
    my $self = shift;
    my ($collector) = @_;

    # Final snapshot: prefer the latest cached run_mutation payload
    # (the event stream is authoritative once it's flowing); fall
    # back to spec->TO_JSON if no event ever arrived; else write an
    # empty stub. Stamp exit / pass onto whatever shape we end up
    # with if the caller still wants per-collector metadata.
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

    $self->output_files unless defined $self->{+OUTPUT_FILE};
    write_json_file_atomic($self->{+OUTPUT_FILE}, $data);
}

# ----------------------------------------------------------------------
# Streamer interface. Snapshot-style: file is atomically replaced on
# each write. The reader is a plain Test2::Harness2::Util::File::JSON
# object -- its base class handles change detection (Linux::Inotify2
# when available, stat-tuple fallback) and read_if_changed() layers
# on top of that.
sub update_style           { 'replace' }
sub records_state          { 1 }
sub records_general_events { 0 }

sub log_reader {
    my ($class, $path) = @_;
    return Test2::Harness2::Util::File::JSON->new(name => $path);
}

sub ready {
    my ($class, $r) = @_;
    return 0 unless $r;
    return $r->changed ? 1 : 0;
}

# read_if_changed returns empty list when nothing is new. Squash
# that to undef so fetch_state's scalar contract stays
# "snapshot-or-nothing". The empty-list distinction is useful at the
# File layer but the role consumers only care about whether there
# is a new snapshot to diff.
sub fetch_state {
    my ($class, $r) = @_;
    return undef unless $r;
    my @out = $r->read_if_changed;
    return @out ? $out[0] : undef;
}

# Snapshot-style state logger: no general event stream to pass
# through, the role requires the method, so return the empty list.
sub fetch_events { () }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::JSON - Snapshot-style JSON sidecar logger.

=head1 DESCRIPTION

A collector logger that writes a C<.json> file next to the streaming
L<JSONL|Test2::Harness2::Collector::Logger::JSONL> log. The file is
always the current "full snapshot" of whatever state the logger is
tracking, written atomically so readers never see a partial write.

Two feeding modes:

=over 4

=item Event-driven (run services, harness service)

The run-service collector emits a C<run_mutation> event every time
the run's state changes, carrying the full C<Run->TO_JSON> payload.
Logger::JSON caches whichever was most recent and overwrites the
sidecar on shutdown. The initial snapshot at startup comes from the
(optional) C<spec> or from an empty stub.

=item Static (snapshot from a spec)

If no C<run_mutation> events ever arrive -- for example, per-job
collectors where the test job itself has no mutating state -- the
logger falls back to whatever C<spec> was passed in at construction.
If neither is present, the shutdown write carries only the
collector's exit status and (when an auditor is attached) the
auditor's pass/fail verdict.

=back

=head1 ATTRIBUTES

=over 4

=item ipcm_info (required)

IPC::Manager route info forwarded from the collector.

=item output_file (optional)

Explicit path for the C<.json> file. When omitted, the logger role's
path derivation builds one from the collector's identity
(C<logdir> / C<run_id> / C<job_id> / C<service_name>, etc.).

=item spec (optional)

An object implementing C<TO_JSON>. Used for the startup snapshot
and as a shutdown fallback when no C<run_mutation> events arrived.

=back

=head1 METADATA

L</metadata> returns C<< { json_file => $output_file } >> so the
C<collector_artifacts> message published at collector startup carries
a locator for the sidecar.

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
