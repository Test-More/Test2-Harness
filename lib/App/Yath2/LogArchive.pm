package App::Yath2::LogArchive;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd ();
use File::Spec ();
use Time::HiRes ();

# The base class provides factory dispatch, not state. Subclasses
# (Directory, TarZIdx) use Object::HashBase themselves and define
# their own attribute slots; the base class's only blessable slot
# is the lazy logger-class cache populated on first ext lookup.
use constant _LOGGER_MAP => '_logger_map';

use Test2::Harness2::Util qw/load_module/;

use Test2::Harness2::LogLayout qw/
    run_dir
    run_spec_basename
    run_state_basename
    run_events_basename
/;

use App::Yath2::LogArchive::Artifact;

# Logger class lookup is by extension: an artifact ending in .xyz is
# produced by Test2::Harness2::Collector::Logger::XYZ (also tried with
# Capital and lowercase casings, in that order). Loggers expose
# update_type so we know whether a given physical file is an
# append-stream or a replace-snapshot; everything else (the file
# extension, the produced path) is derivable without asking the
# logger.
use constant LOGGER_NAMESPACE => 'Test2::Harness2::Collector::Logger';

# {{{ Construction / factory

# Factory: open an existing archive in either form, dispatching to
# the right backend. Direct construction (when the kind is already
# known) goes through the backend's own ->new.
#
#     App::Yath2::LogArchive->open(file => '/path/to/run.yath')  # TarZIdx
#     App::Yath2::LogArchive->open(dir  => '/path/to/logs')      # Directory
#     App::Yath2::LogArchive->open(path => $auto)                # -d decides
sub open {
    my ($class, %args) = @_;

    my $file = delete $args{file};
    my $dir  = delete $args{dir};
    my $path = delete $args{path};

    croak "Pass exactly one of 'file', 'dir', or 'path'"
        if 1 != grep { defined($_) } $file, $dir, $path;

    my $is_dir;
    if (defined $file) {
        croak "file '$file' does not exist" unless -e $file;
        croak "file '$file' is a directory; use dir => ..." if -d $file;
        $path   = $file;
        $is_dir = 0;
    }
    elsif (defined $dir) {
        croak "dir '$dir' does not exist"     unless -e $dir;
        croak "dir '$dir' is not a directory" unless -d $dir;
        $path   = $dir;
        $is_dir = 1;
    }
    else {
        croak "path '$path' does not exist" unless -e $path;
        $is_dir = -d $path ? 1 : 0;
    }

    if ($is_dir) {
        require App::Yath2::LogArchive::Directory;
        return App::Yath2::LogArchive::Directory->new(path => $path, %args);
    }

    require App::Yath2::LogArchive::TarZIdx;
    return App::Yath2::LogArchive::TarZIdx->new(path => $path, %args);
}

# }}}

# {{{ Latest-archive discovery + last_log.yath symlink

# Filename of the in-cwd symlink that always points at the most
# recent archive a `yath test` produced from this working directory.
# Consumers (yath replay, yath extract, yath failed, ...) honour it
# when no explicit log path was given on the command line.
use constant LAST_LOG_SYMLINK => 'last_log.yath';

# Locate the most recent log archive for the current cwd.
#
#   1. ./last_log.yath -- if present, the symlink target wins.
#      (The symlink may itself live in cwd or, if a wrapper has
#      cd'd elsewhere, be passed an explicit $cwd.)
#   2. Glob ${TMPDIR}/${project}-${user}-*.yath. Sort by the stamp
#      embedded in the filename; ties (same-second runs) are broken
#      by hi-res mtime.
#
# Returns the absolute path of the winning archive, or undef when
# nothing matches.
sub find_latest {
    my ($class, $settings) = @_;
    croak "settings is required" unless defined $settings;

    my $cwd = $settings->yath->cwd // Cwd::getcwd();

    my $sym = File::Spec->catfile($cwd, LAST_LOG_SYMLINK);
    if (-l $sym || -e $sym) {
        return $sym;
    }

    my $project = $settings->yath->project;
    my $user    = $settings->yath->user;
    return undef unless defined $project && length $project;
    return undef unless defined $user    && length $user;

    # __UNKNOWN__ means we could not pin the project to a specific
    # codebase. Refuse to glob across all projects and let the
    # caller report the no-archive condition.
    return undef if $project eq '__UNKNOWN__';

    my $tmp     = File::Spec->tmpdir();
    my $pattern = File::Spec->catfile($tmp, "${project}-${user}-*.yath");

    my @hits;
    for my $path (glob $pattern) {
        next unless -f $path;
        my ($name) = File::Spec->splitpath($path) ? (File::Spec->splitpath($path))[2] : $path;
        my ($stamp) = $name =~ m{-(\d{8}-\d{6})-\d+\.yath\z}
            or next;
        my $mtime = (Time::HiRes::stat($path))[9] // 0;
        push @hits => [$stamp, $mtime, $path];
    }
    return undef unless @hits;

    @hits = sort { $b->[0] cmp $a->[0] || $b->[1] <=> $a->[1] } @hits;
    return $hits[0][2];
}

# Update (or create) the ./last_log.yath symlink in the given
# directory so it points at $archive_path. Replaces any existing
# symlink atomically; refuses to overwrite a regular file at the
# target path so the user does not lose data through a stale name
# clash.
sub update_last_log_symlink {
    my ($class, $archive_path, %p) = @_;
    croak "archive_path is required" unless defined $archive_path && length $archive_path;

    my $cwd = $p{cwd} // Cwd::getcwd();
    my $sym = File::Spec->catfile($cwd, LAST_LOG_SYMLINK);

    if (-e $sym && !-l $sym) {
        warn "refusing to replace non-symlink '$sym' with last_log.yath\n";
        return;
    }

    unlink $sym if -l $sym;
    symlink($archive_path, $sym)
        or warn "could not create symlink '$sym' -> '$archive_path': $!\n";

    return $sym;
}

# }}}

# {{{ Required backend contract (subclasses fill these in)

sub is_live      { 0 }    # Directory backend overrides when a live workdir
sub static       { $_[0]->is_live ? 0 : 1 }
sub list_files   { croak "list_files is not implemented for " . ref($_[0]) }
sub has_file     { croak "has_file is not implemented for "   . ref($_[0]) }
sub read_file    { croak "read_file is not implemented for "  . ref($_[0]) }
sub absolute_path {
    croak "absolute_path is not implemented for " . ref($_[0]);
}

# Relative directory paths visible to this backend, no leading slash,
# no trailing slash, and no ordering guarantee. The Directory backend
# walks the filesystem; the TarZIdx backend derives parent paths from
# list_files (and, when present, explicit directory entries in the
# index).
sub list_dirs    { croak "list_dirs is not implemented for "  . ref($_[0]) }

# Writers. Default implementations route through the cross-backend
# helper: read everything via list_files / read_file and write to a
# new instance. Backends that have a more efficient native form
# override.
sub archive {
    my ($self, $out, %opts) = @_;
    croak "archive() is not implemented for " . ref($self);
}

sub extract {
    my ($self, $dir, %opts) = @_;
    croak "extract() is not implemented for " . ref($self);
}

# }}}

# {{{ Artifacts API

# $la->artifacts                       -> harness-scope (no run-scope entries)
# $la->artifacts($run_id)              -> per-run (no job-scope entries)
# $la->artifacts($run_id, $job_id)     -> per-job, keyed by try number
#
# All three return:
#
#   {
#       append  => { logical_name => [physical_paths...] },
#       replace => { logical_name => [physical_paths...] },
#   }
#
# 'logical_name' is the artifact's logical key (no extension). For
# global / run scope this is a path-like key (e.g. 'services/harness',
# 'events', 'spec', 'state'). For job scope the keys are stringified
# integer try numbers ('0', '1', ...).
#
# update_type ('append' / 'replace') comes from the logger that
# produced the artifact, looked up by extension via _logger_for_ext.
# Files whose extension has no installed logger are skipped silently.
sub artifacts {
    my $self = shift;
    my ($run_id, $job_id) = @_;

    croak "run_id is required when job_id is given"
        if defined $job_id && !defined $run_id;

    my %append;
    my %replace;

    if (defined $job_id) {
        # Job scope: keep only files under runs/<run>/tests/<job>/
        # and key by the try number (the extension-less basename).
        my $prefix = run_dir($run_id) . "/tests/$job_id/";
        for my $rel ($self->list_files) {
            next unless index($rel, $prefix) == 0;
            my $tail = substr($rel, length $prefix);
            next if $tail =~ m{/};    # nested dir, not a leaf

            my ($try, $ext) = $self->_split_path_ext($tail) or next;
            my $info = $self->_logger_for_ext($ext) or next;

            my $bucket = $info->{update_type} eq 'append' ? \%append : \%replace;
            push @{$bucket->{$try}} => $rel;
        }
    }
    elsif (defined $run_id) {
        # Run scope: files under runs/<run>/, excluding tests/<job>/
        # (those are job-scope) and excluding any nested service
        # subdirectory entries that key by sub-path.
        my $prefix = run_dir($run_id) . "/";
        for my $rel (sort $self->list_files) {
            next unless index($rel, $prefix) == 0;
            my $tail = substr($rel, length $prefix);
            next if $tail =~ m{^tests/};

            my ($base, $ext) = $self->_split_path_ext($tail) or next;
            my $info = $self->_logger_for_ext($ext) or next;

            my $bucket = $info->{update_type} eq 'append' ? \%append : \%replace;
            push @{$bucket->{$base}} => $rel;
        }
    }
    else {
        # Global scope: drop everything under runs/ (those scopes
        # are reached separately).
        for my $rel (sort $self->list_files) {
            next if $rel =~ m{^runs/};

            my ($base, $ext) = $self->_split_path_ext($rel) or next;
            my $info = $self->_logger_for_ext($ext) or next;

            my $bucket = $info->{update_type} eq 'append' ? \%append : \%replace;
            push @{$bucket->{$base}} => $rel;
        }
    }

    return {append => \%append, replace => \%replace};
}

# Split 'foo.jsonl' or 'foo.jsonl.zst' (or a path with slashes,
# e.g. 'services/harness.jsonl') into ('foo' / 'services/harness',
# 'jsonl'). Returns undef on a name that does not look like
# basename.ext or basename.ext.zst.
sub _split_path_ext {
    my ($self, $rel) = @_;
    return unless defined $rel && length $rel;
    return unless $rel =~ m{^(.+?)\.([^./]+)(?:\.zst)?\z};
    return ($1, $2);
}

# Files in the archive whose logical name (everything before the
# extension and any .zst suffix) equals $logical_prefix.
sub _files_with_logical_prefix {
    my ($self, $logical_prefix) = @_;
    my @hits;
    for my $rel ($self->list_files) {
        next unless $rel =~ m{^\Q$logical_prefix\E\.[^./]+(?:\.zst)?\z};
        push @hits => $rel;
    }
    return @hits;
}

# }}}

# {{{ Listing methods

# Run IDs present in the archive. Existence is keyed on the
# `runs/<id>/` directory: if the directory is visible to the
# backend, the run exists, even when no artifact files have landed
# inside it yet. Same shape for jobs() and services().
sub runs {
    my $self = shift;
    return sort keys %{ $self->_immediate_children('runs') };
}

# Job IDs in a given run. Existence is keyed on the
# `runs/<run>/tests/<job>/` directory.
sub jobs {
    my ($self, $run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return sort keys %{ $self->_immediate_children("runs/$run_id/tests") };
}

# Service names. Without args: harness-scope services under
# `services/<name>/`. With $run_id: run-scoped services under
# `runs/<run>/services/<name>/`. Existence is keyed on directory
# presence.
sub services {
    my ($self, $run_id) = @_;
    my $prefix = defined $run_id ? "runs/$run_id/services" : "services";
    return sort keys %{ $self->_immediate_children($prefix) };
}

# Names of immediate child directories of $prefix. Walks list_dirs
# and matches paths exactly one level beneath $prefix.
sub _immediate_children {
    my ($self, $prefix) = @_;
    my %names;
    for my $dir ($self->list_dirs) {
        next unless $dir =~ m{^\Q$prefix\E/([^/]+)\z};
        $names{$1} = 1;
    }
    return \%names;
}

# }}}

# {{{ Artifact accessor

# Build (or fetch a cached) Artifact handle for one logical artifact.
#
#     my $a = $la->artifact('runs/RUN/events');
#     my $a = $la->artifact('runs/RUN/events', prefer => ['jsonl', 'csv']);
#
# 'prefer' is an ordered list of file extensions; the first extension
# whose physical form is on disk wins. Returns undef if no matching
# physical artifact exists.
sub artifact {
    my ($self, $logical, %opts) = @_;
    croak "logical path is required" unless defined $logical && length $logical;

    my $prefer = $opts{prefer} // [];
    croak "'prefer' must be an array reference" unless ref($prefer) eq 'ARRAY';

    # Discover physical-file extensions for this logical name by
    # scanning the archive. Extensions the caller listed in 'prefer'
    # come first (in the order given), then everything else in
    # alphabetical order so the resolution is deterministic.
    my %disk_ext;
    for my $rel ($self->_files_with_logical_prefix($logical)) {
        my (undef, $ext) = $self->_split_path_ext($rel);
        $disk_ext{$ext} = $rel if defined $ext;
    }

    my @ext_order;
    my %seen;
    for my $ext (@$prefer) {
        next if $seen{$ext}++;
        next unless exists $disk_ext{$ext};
        push @ext_order => $ext;
    }
    for my $ext (sort keys %disk_ext) {
        next if $seen{$ext}++;
        push @ext_order => $ext;
    }

    return undef unless @ext_order;

    for my $ext (@ext_order) {
        my $info = $self->_logger_for_ext($ext);
        next unless $info;

        for my $cand ("$logical.$ext.zst", "$logical.$ext") {
            next unless $self->has_file($cand);
            return App::Yath2::LogArchive::Artifact->new(
                archive      => $self,
                relpath      => $cand,
                logical_name => $logical,
                logger_class => $info->{class},
                update_type  => $info->{update_type},
            );
        }
    }

    croak "No installed logger handles any of: "
        . join(', ', map { ".$_" } @ext_order)
        . " for artifact '$logical' -- install the matching "
        . LOGGER_NAMESPACE . "::* class";
}

# Return the FileMonitor for $logical via $self->artifact($logical)->watch.
# Convenience wrapper for the common one-liner.
sub watch_artifact {
    my ($self, $logical, %opts) = @_;
    my $a = $self->artifact($logical, %opts);
    return undef unless $a;
    return $a->watch;
}

# Flat iterator: returns ($rel => $logger_class) pairs covering every
# artifact in scope. Convenience for consumers (e.g. Streamer::Static)
# that walk physical files and dispatch by logger class. Files with
# no installed logger for their extension are skipped silently.
sub iter_artifacts {
    my ($self, $run_id, $job_id) = @_;

    croak "run_id is required when job_id is given"
        if defined $job_id && !defined $run_id;

    my @out;
    for my $rel (sort $self->list_files) {
        if (defined $job_id) {
            my $tests_prefix = run_dir($run_id) . "/tests/";
            next unless index($rel, $tests_prefix) == 0;
            my $tail = substr($rel, length $tests_prefix);
            next unless $tail =~ m{^\Q$job_id\E/[^/]+\z};
        }
        elsif (defined $run_id) {
            my $prefix = run_dir($run_id) . "/";
            next unless index($rel, $prefix) == 0;
            my $tail = substr($rel, length $prefix);
            next if $tail =~ m{^tests/};
        }
        else {
            next if $rel =~ m{^runs/};
        }

        my (undef, $ext) = $self->_split_path_ext($rel);
        next unless defined $ext;
        my $info = $self->_logger_for_ext($ext) or next;
        push @out => ($rel => $info->{class});
    }

    return @out;
}

# }}}

# {{{ Internal helpers

# Lookup a logger class for the given on-disk file extension.
#
# Try Test2::Harness2::Collector::Logger::<UPPER>, then <Capital>,
# then <lower>. First class that loads wins. Each result is cached
# (positive or negative); subsequent lookups for the same ext skip
# the load attempts.
#
# Returns { class => $name, update_type => 'append'|'replace' } or
# undef when no logger is installed for that extension.
sub _logger_for_ext {
    my ($self, $ext) = @_;
    return undef unless defined $ext && length $ext;

    my $cache = $self->{+_LOGGER_MAP} //= {};
    return $cache->{$ext} if exists $cache->{$ext};

    my @candidates = (uc $ext, ucfirst lc $ext, lc $ext);
    my %seen;
    for my $cand (grep { !$seen{$_}++ } @candidates) {
        my $class = LOGGER_NAMESPACE . '::' . $cand;
        next unless eval { load_module($class); 1 };
        next unless $class->can('update_type');
        $cache->{$ext} = {
            class       => $class,
            update_type => $class->update_type,
        };
        return $cache->{$ext};
    }

    $cache->{$ext} = undef;
    return undef;
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive - Read and write yath log archives.

=head1 SYNOPSIS

    use App::Yath2::LogArchive;

    # Factory: open an existing archive (directory or .yath file).
    my $la = App::Yath2::LogArchive->open(file => '/path/to/run.yath');
    my $la = App::Yath2::LogArchive->open(dir  => '/path/to/logs');
    my $la = App::Yath2::LogArchive->open(path => $auto);    # detects

    # Listing.
    my @runs = $la->runs;
    my @jobs = $la->jobs($run_id);
    my @svc  = $la->services;
    my @rsv  = $la->services($run_id);

    # Artifacts API. Returns
    # { append => { name => [paths...] }, replace => { name => [paths...] } }.
    my $global   = $la->artifacts;
    my $run_scope = $la->artifacts($run_id);
    my $job_scope = $la->artifacts($run_id, $job_id);

    # Artifact handles.
    my $a = $la->artifact('runs/RUN/events');             # auto extension
    my $a = $la->artifact('runs/RUN/events',
                          prefer => ['jsonl', 'csv']);

    # Transform ops (return the new LogArchive instance).
    my $arc = App::Yath2::LogArchive->open(dir => '/logs')
                  ->archive('/out/run.yath');

    my $dir = App::Yath2::LogArchive->open(file => '/out/run.yath')
                  ->extract('/out/extracted');

=head1 DESCRIPTION

Single-interface, dual-backend abstraction over a yath log tree.
Two backends ship in-tree: a directory backend
(L<App::Yath2::LogArchive::Directory>) that reads and writes a live
or extracted log directory, and a tar.zidx backend
(L<App::Yath2::LogArchive::TarZIdx>) that reads and writes the
single-file C<.yath> archive format yath produces.

The base class is the factory + shared methods. Subclasses fill in
C<list_files>, C<has_file>, C<read_file>, C<absolute_path>,
C<archive>, and C<extract>.

=head1 SEE ALSO

L<App::Yath2::LogArchive::Directory> -- directory backend.

L<App::Yath2::LogArchive::TarZIdx> -- tar.zidx backend.

L<App::Yath2::LogArchive::Artifact> -- handle for an individual
artifact.

L<Test2::Harness2::LogLayout> -- path templates.

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
