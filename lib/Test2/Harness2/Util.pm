package Test2::Harness2::Util;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Fcntl qw/LOCK_EX LOCK_UN/;
use Importer Importer => 'import';
use Test2::Util qw/try_sig_mask do_rename/;

our @EXPORT_OK = qw{
    apply_encoding
    close_file
    hub_truth
    load_module
    lock_file
    maybe_open_file
    maybe_read_file
    mod2file
    open_file
    parse_exit
    read_file
    tinysleep
    unlock_file
    write_file
    write_file_atomic
};

# Load a Perl module by its :: name, idempotently. Returns the module
# name. Short-circuits when %INC already has the file or the package
# stash is already populated, so repeated calls (or calls for modules
# that were brought in by some other path) are cheap. Dies (via the
# underlying require) if the module cannot be loaded.
sub load_module {
    my ($name) = @_;
    croak "load_module: module name is required"
        unless defined $name && length $name;

    my $file = mod2file($name);
    return $name if $INC{$file};
    {
        no strict 'refs';
        return $name if %{"${name}::"};
    }
    require $file;
    return $name;
}

# Short sub-second sleep that returns early when a signal arrives.
# Time::HiRes::sleep retries internally on EINTR, so a long nap will
# silently swallow signals; polling loops that want to react to
# SIGCHLD / SIGTERM promptly should use this instead. Implemented
# over four-arg select(), which returns -1 on EINTR.
sub tinysleep {
    my ($secs) = @_;
    return if !defined $secs || $secs <= 0;
    select(undef, undef, undef, $secs);
    return;
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub apply_encoding {
    my ($fh, $enc) = @_;
    return unless $enc;

    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    binmode($fh, ":encoding($enc)");
}

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace}     if $f->{trace};
    return {};
}

sub parse_exit {
    my ($exit) = @_;
    croak "an exit value is required" unless defined $exit;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

# Compression readers recognised by open_file(). Only used on read; writes
# go through plain open() regardless of extension.
my %COMPRESSION = (
    bz2 => {module => 'IO::Uncompress::Bunzip2', errors => \$IO::Uncompress::Bunzip2::Bunzip2Error},
    gz  => {module => 'IO::Uncompress::Gunzip',  errors => \$IO::Uncompress::Gunzip::GunzipError},
);

# Open $file for $mode (default '<'). For read mode, files whose name ends
# in .gz or .bz2 (or an explicit 'ext'/'compression' option) are opened via
# the matching IO::Uncompress::* module so callers get a normal-looking
# filehandle over compressed data. Dies on failure; the 'no_decompress'
# opt bypasses compression detection entirely.
sub open_file {
    my ($file, $mode, %opts) = @_;
    $mode ||= '<';

    unless ($opts{no_decompress}) {
        if (my $ext = $opts{ext}) {
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($file =~ m/\.(gz|bz2)$/i) {
            my $ext = lc($1);
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($mode eq '<' && $opts{compression}) {
            my $spec = $opts{compression};
            my $mod  = $spec->{module};
            require(mod2file($mod));

            my $fh = $mod->new($file) or die "Could not open file '$file' ($mode): ${$spec->{errors}}";
            return $fh;
        }
    }

    open(my $fh, $mode, $file) or confess "Could not open file '$file' ($mode): $!";
    return $fh;
}

sub maybe_open_file {
    my ($file, $mode) = @_;
    return undef unless -f $file;
    return open_file($file, $mode);
}

sub close_file {
    my ($fh, $name) = @_;
    return if close($fh);
    confess "Could not close file: $!" unless $name;
    confess "Could not close file '$name': $!";
}

sub read_file {
    my ($file, @args) = @_;

    my $fh = open_file($file, '<', @args);
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

sub maybe_read_file {
    my ($file) = @_;
    return undef unless -f $file;
    return read_file($file);
}

sub write_file {
    my ($file, @content) = @_;

    my $fh = open_file($file, '>');
    print $fh @content;
    close_file($fh, $file);

    return @content;
}

# Advisory lock helpers over flock(). lock_file accepts either a filename
# (opened for append unless $mode overrides) or an already-open handle,
# and retries up to 20 times on EINTR/ERESTART before giving up. Callers
# must pair lock_file with unlock_file (or close the handle) to release.
sub lock_file {
    my ($file, $mode) = @_;

    my $fh;
    if (ref $file) {
        $fh = $file;
    }
    else {
        open($fh, $mode // '>>', $file) or die "Could not open file '$file': $!";
    }

    for (1 .. 21) {
        flock($fh, LOCK_EX) and last;
        die "Could not lock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not lock file: $!";
    }

    return $fh;
}

sub unlock_file {
    my ($fh) = @_;
    for (1 .. 21) {
        flock($fh, LOCK_UN) and last;
        die "Could not unlock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not unlock file: $!";
    }

    return $fh;
}

# Write @content to "$file.pend" and then do_rename() it over $file.  Signal
# masking keeps the half-written pending file from being abandoned if the
# process is signalled mid-write.  Callers that need richer encoding (e.g.
# JSON) layer their own helper on top; see write_json_file_atomic in
# Test2::Harness2::Util::JSON.
sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        write_file($pend, @content);
        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    unless ($ok) {
        unlink($pend);
        die $err;
    }

    return @content;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util - Small shared utility functions used across the harness.

=head1 SYNOPSIS

    use Test2::Harness2::Util qw/apply_encoding hub_truth mod2file parse_exit/;

    my $file  = mod2file('Foo::Bar');         # 'Foo/Bar.pm'
    my $hub   = hub_truth($facet_data);       # canonical hub/trace facet
    my $codes = parse_exit($?);               # { sig, err, dmp, all }

    apply_encoding(\*STDOUT, 'utf8');         # binmode helper

=head1 EXPORTS

All exports are optional and must be requested explicitly.

=over 4

=item apply_encoding($fh, $encoding)

Apply C<$encoding> to C<$fh> via C<binmode>. Returns immediately when
C<$encoding> is false. Uses C<:utf8> for any C<utf-?8> spelling to avoid the
thread segfault from C<:encoding(utf8)>; for any other encoding uses
C<:encoding($encoding)>.

=item $name = load_module($module_name)

Load C<$module_name> via C<require>, idempotently. Short-circuits when
C<%INC> already records the file or the package stash is populated, so
repeated calls (or calls for modules pulled in by another path) do no
work. Returns the module name on success; propagates the underlying
C<require> exception on failure. Use this wherever the harness
dynamically loads a class by string name.

=item $path = mod2file($module_name)

Convert a Perl module name (C<Foo::Bar::Baz>) to its C<%INC>-style relative
path (C<Foo/Bar/Baz.pm>). Confesses if the module name is undefined.

=item $facet = hub_truth($facet_data)

Return the authoritative hub/trace facet from a Test2 facet-data hash. Prefers
C<< $facet_data->{hubs}->[0] >> when present, falls back to
C<< $facet_data->{trace} >>, and returns an empty hashref if neither is
populated.

=item $codes = parse_exit($wstat)

Decode a wait-status integer (typically C<$?>) into a hashref:

=over 4

=item C<sig> -- the low 7 bits (signal number, or 0)

=item C<err> -- the upper bits shifted right 8 (exit code)

=item C<dmp> -- bit 7 (core-dump flag)

=item C<all> -- the original raw value

=back

Croaks if C<$wstat> is undefined.

=item tinysleep($seconds)

Sub-second sleep that returns early when a signal arrives. Backed by
four-arg C<select()>, which returns C<-1> on C<EINTR>, so a signal
received mid-nap causes an immediate return instead of being delayed
by the rest of the interval. Prefer this over C<Time::HiRes::sleep>
inside polling loops (C<waitpid> reapers, TERM-then-KILL escalation,
readiness waits) where prompt signal response matters. Returns
nothing. A non-positive or undefined argument is a no-op.

=item $fh = open_file($path)

=item $fh = open_file($path, $mode)

=item $fh = open_file($path, $mode, %opts)

Open C<$path> and return the handle. The default mode is C<< '<' >>.
When opening for read, C<.gz> / C<.bz2> extensions trigger transparent
decompression via L<IO::Uncompress::Gunzip> / L<IO::Uncompress::Bunzip2>;
pass C<< no_decompress =E<gt> 1 >> to disable that behaviour, or
C<< ext =E<gt> 'gz' >> / C<< ext =E<gt> 'bz2' >> to force a specific
compression when the filename does not carry the usual extension.

Dies with a C<confess>-style message on failure.

=item $fh = maybe_open_file($path)

=item $fh = maybe_open_file($path, $mode)

Like L</open_file>, but returns C<undef> when C<$path> is not a regular
file instead of raising an exception. Intended for "read if present"
callers.

=item close_file($fh)

=item close_file($fh, $name)

Wrap C<close()> with a clearer error. The optional C<$name> is included
in the diagnostic when the close fails.

=item $content = read_file($path, %open_opts)

Slurp C<$path> in full and return the result. Extra options are passed
through to L</open_file> (e.g. for explicit compression handling). Dies
on any I/O failure.

=item $content = maybe_read_file($path)

Like L</read_file>, but returns C<undef> when C<$path> is not a regular
file instead of raising an exception.

=item write_file($path, @content)

Open C<$path> for write, print C<@content>, and close. Dies on any I/O
failure. For crash-safe writes use L</write_file_atomic>.

=item $fh = lock_file($path_or_fh)

=item $fh = lock_file($path, $mode)

Acquire an exclusive advisory lock via C<flock(LOCK_EX)>. Accepts either
a filename (opened in C<< '>>' >> mode unless C<$mode> is supplied) or an
already-open handle. Retries up to 20 times on C<EINTR>/C<ERESTART>
before giving up. Returns the locked handle; pair with L</unlock_file>
(or simply close the handle) to release.

=item unlock_file($fh)

Release an advisory lock acquired via L</lock_file>. Retries on
C<EINTR>/C<ERESTART> the same way as acquisition.

=item write_file_atomic($path, @content)

Write C<@content> to C<$path> atomically: writes to C<"$path.pend"> first,
then C<do_rename()>s it over the target under a signal mask so an
interrupt cannot leave a half-written file in place.  Dies on any I/O
failure; the pending file is removed on error.

=back

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
