package Test2::Harness2::Util;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Cwd qw/realpath/;
use File::Spec ();
use Importer Importer => 'import';

our @EXPORT_OK = qw{
    apply_encoding
    clean_path
    file2mod
    hub_truth
    mod2file
    parse_exit
};

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub file2mod {
    my ($file) = @_;
    confess "No filename provided" unless defined $file && length $file;
    my $mod = $file;
    $mod =~ s{/}{::}g;
    $mod =~ s/\.[^.]*$//;
    return $mod;
}

sub clean_path {
    my ($path, $absolute) = @_;

    confess "No path was provided to clean_path()" unless defined $path && length $path;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
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

=item $path = mod2file($module_name)

Convert a Perl module name (C<Foo::Bar::Baz>) to its C<%INC>-style relative
path (C<Foo/Bar/Baz.pm>). Confesses if the module name is undefined.

=item $module = file2mod($path)

Inverse of C<mod2file>. Convert a filename like C<Foo/Bar/Baz.pm> to the
module name C<Foo::Bar::Baz>. Strips the final extension; slashes become
C<::>. Confesses if the filename is undefined or empty.

=item $abs = clean_path($path, $absolute)

Return C<$path> converted to an absolute, realpath-resolved path. When
C<$absolute> is false, the realpath resolution is skipped but the path is
still made absolute via L<File::Spec/rel2abs>. Confesses when the path is
undefined or empty.

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
