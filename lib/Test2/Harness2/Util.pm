package Test2::Harness2::Util;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Importer Importer => 'import';
use Test2::Util qw/try_sig_mask do_rename/;

our @EXPORT_OK = qw{
    apply_encoding
    hub_truth
    load_module
    mod2file
    parse_exit
    tinysleep
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

# Write @content to "$file.pend" and then do_rename() it over $file.  Signal
# masking keeps the half-written pending file from being abandoned if the
# process is signalled mid-write.  Callers that need richer encoding (e.g.
# JSON) layer their own helper on top; see write_json_file_atomic in
# Test2::Harness2::Util::JSON.
sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        open(my $fh, '>', $pend) or die "Could not open '$pend' (>): $!";
        print $fh @content;
        close($fh) or die "Could not close '$pend': $!";
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
