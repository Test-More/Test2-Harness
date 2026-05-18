package App::Yath2::Command::reformat;
use strict;
use warnings;

our $VERSION = '2.000013';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use Carp qw/croak/;
use File::Spec ();

use App::Yath2::Log();
use App::Yath2::Formatter::Txt();
use App::Yath2::Renderer2::ArtifactWriter qw/update_meta_formatters/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 0 }
sub group              { 'log parsing' }
sub summary            { 'Rebuild formatter artifacts in a log' }

sub cli_args { "[--] LOG [OUTLOG]" }

sub description {
    return <<"    EOT";
Rebuild formatter artifacts in a log so they match the current
formatter versions shipped with this yath. Useful after a yath
upgrade has shipped new formatter output.

With one argument:  rebuild in place. Requires a writable log
(live or directory).

With two arguments: write a refreshed copy of the log at OUTLOG. The
original LOG is untouched. This is the supported path for read-only
logs (tarball, sqlite).

The meta.json formatter-versions block is updated alongside any
rebuilt artifacts so future readers can tell which formatter version
produced the bytes on disk.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];
    shift @$args if @$args && $args->[0] eq '--';

    my $log_arg = shift @$args;
    unless (defined $log_arg && length $log_arg) {
        $log_arg = App::Yath2::Log->find_latest($settings);
        print STDERR "yath reformat: using latest log: $log_arg\n"
            if defined $log_arg && length $log_arg;
    }

    die "Usage: yath reformat LOG [OUTLOG]\n"
        unless defined $log_arg && length $log_arg;

    die "Log source '$log_arg' does not exist\n"
        unless -e $log_arg;

    my $outlog = shift @$args;
    die "extra arguments after OUTLOG\n" if @$args;

    my $log = App::Yath2::Log->new(auto => $log_arg);

    my $writable_log;
    my $in_place;
    if (defined $outlog && length $outlog) {
        die "OUTLOG '$outlog' already exists\n" if -e $outlog;

        # Materialise the source into a writable directory at OUTLOG.
        # Directory and TarZIdx both implement extract(); Live and DB
        # do too but won't normally show up in this path.
        require File::Path;
        File::Path::make_path($outlog)
            or die "could not create OUTLOG '$outlog': $!\n"
            unless -d $outlog;

        $log->extract($outlog);
        $writable_log = App::Yath2::Log->new(dir => $outlog);
        $in_place     = 0;
        print "Reformat: copied '$log_arg' to '$outlog' for rewrite\n";
    }
    else {
        die "In-place reformat requires a writable log (live or directory). " . "For read-only logs (tarball, sqlite), use 'yath reformat LOG OUTLOG'.\n"
            unless _log_is_writable($log);
        $writable_log = $log;
        $in_place     = 1;
    }

    my $logdir = _logdir_for($writable_log);
    die "reformat: could not resolve writable log directory\n"
        unless defined $logdir && -d $logdir;

    my $stats = _rebuild_artifacts($writable_log, $logdir);

    my $version_map = {txt => $App::Yath2::Formatter::Txt::VERSION // '0'};
    my $ok          = eval { update_meta_formatters($logdir, $version_map); 1 };
    unless ($ok) {
        warn "reformat: meta.json update skipped: $@";
    }

    printf "Reformat: %d job(s) processed, %d artifact(s) written, %d skipped (already present)\n",
        $stats->{jobs}, $stats->{written}, $stats->{skipped};

    return 0;
}

# Test whether the Log backend supports in-place writes. Mirrors the
# check in App::Yath2::Command::render and uses class-name rather than
# expanding the public Log role contract.
sub _log_is_writable {
    my $log   = shift;
    my $class = ref($log);
    return 1 if $class eq 'App::Yath2::Log::Live';
    return 1 if $class eq 'App::Yath2::Log::Directory';
    return 0;
}

# Pull the filesystem root out of a writable Log. Both Live and
# Directory expose ->path; nothing else needs to land in this branch
# because _log_is_writable already gated us.
sub _logdir_for {
    my $log = shift;
    return unless $log->can('path');
    return $log->path;
}

# Walk every job in every run, generate the Txt formatter artifact
# for its events feed, and publish it via write_artifact_atomic. Skips
# jobs whose artifact is already present (existing-file-wins semantics
# match the artifact writer's behaviour).
#
# Stage 8 ships v1 of this loop: Txt only, jobs only. Tty has
# produces_artifact=0 (settings-bearing) and is never persisted as a
# formatter artifact. Run/service/collector artifacts are not yet
# produced; they can be added in follow-up stages without changing
# the command's CLI surface.
sub _rebuild_artifacts {
    my ($log, $logdir) = @_;

    require App::Yath2::Renderer2::ArtifactWriter;
    my $writer = \&App::Yath2::Renderer2::ArtifactWriter::write_artifact_atomic;

    my $formatter = App::Yath2::Formatter::Txt->new;
    return {jobs => 0, written => 0, skipped => 0}
        unless $formatter->produces_artifact;

    my $jobs    = 0;
    my $written = 0;
    my $skipped = 0;

    for my $run_p ($log->run_producers->all) {
        for my $job_p ($log->job_producers($run_p->id)->all) {
            $jobs++;

            my $reader = $job_p->artifact('events');
            next unless $reader;

            my $bytes = '';
            while (defined(my $item = $reader->readline)) {
                $bytes .= $formatter->convert_item($item);
            }
            next unless length $bytes;

            # Mirror the producer's events.jsonl(.zst) sibling: write
            # events.txt(.zst) alongside. Compression matches when the
            # source was compressed; otherwise we write plain bytes.
            my $rel_dir = File::Spec->catdir(
                'runs', $run_p->id, 'jobs', $job_p->id, ($job_p->try // 0),
            );
            my $abs_dir = File::Spec->catdir($logdir, $rel_dir);
            next unless -d $abs_dir;

            my $compressed  = -e File::Spec->catfile($abs_dir, 'events.jsonl.zst');
            my $target_name = $compressed ? 'events.txt.zst' : 'events.txt';
            my $target      = File::Spec->catfile($abs_dir, $target_name);

            my $payload = $bytes;
            if ($compressed) {
                require Compress::Zstd;
                $payload = Compress::Zstd::compress($bytes) // do { warn "reformat: zstd compress failed for $target"; next };
            }

            my $rc = $writer->($target, $payload);
            if ($rc) {
                $written++;
            }
            else {
                $skipped++;
            }
        }
    }

    return {jobs => $jobs, written => $written, skipped => $skipped};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::reformat - Rebuild formatter artifacts in a log.

=head1 SYNOPSIS

    # In-place rewrite (live or directory log).
    yath reformat PATH/TO/LOGDIR

    # Refresh a tarball into a new directory copy.
    yath reformat archive.yath /tmp/refreshed-log

=head1 DESCRIPTION

Walks every job in the log, runs each persistable formatter against
the job's events artifact, and writes the result alongside the source
artifact (e.g. C<events.txt> beside C<events.jsonl>). Existing
artifacts are not overwritten — the atomic writer's
existing-file-wins semantics prevent inode churn and concurrent
clobbers.

After rebuilding, the C<meta.json> formatter-versions block is
updated so future readers can tell which formatter version produced
the bytes on disk.

=head2 Read-only logs

Tarballs (C<.yath>) and sqlite logs are read-only. To reformat one,
supply a second argument; the source is materialised into a writable
directory copy at that path and the rebuild runs there.

=head2 Scope

v1 of this command rebuilds the C<events.txt> artifact for every job
(via L<App::Yath2::Formatter::Txt>). Run-, service-, and
collector-scoped formatter artifacts are not yet produced; they will
be added in follow-up stages without changing this command's CLI.

=head1 SEE ALSO

L<App::Yath2::Command::render>,
L<App::Yath2::Renderer2::ArtifactWriter>,
L<App::Yath2::Formatter::Txt>.

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

See L<http://dev.perl.org/licenses/>

=cut
