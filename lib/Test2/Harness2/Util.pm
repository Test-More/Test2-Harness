package Test2::Harness2::Util;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();
use DateTime   ();

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    apply_encoding
    hub_truth
    now_dt
    share_dir
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util - Leaf utility functions shared across the harness.

=head1 DESCRIPTION

A small bag of standalone helpers with no harness-specific state. Grows as
shared logic is identified; today it carries the encoding helper, the
facet-hub accessor the stream formatter needs, and the C<share_dir> path
resolver.

=head1 SYNOPSIS

    use Test2::Harness2::Util qw/hub_truth apply_encoding share_dir/;

    apply_encoding(\*STDOUT, 'utf-8');
    my $hub = hub_truth($facet_data);
    my $dir = share_dir();

=head1 EXPORTS

=cut

=over 4

=item apply_encoding($fh, $encoding)

Apply C<$encoding> to C<$fh> via C<binmode>. A no-op when C<$encoding> is
false. C<utf-8> / C<utf8> map to the C<:utf8> layer; anything else goes
through C<:encoding($enc)>.

=back

=cut

sub apply_encoding ($fh, $enc) {
    return unless $enc;

    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    return binmode($fh, ":encoding($enc)");
}

=over 4

=item $facet = hub_truth($facet_data)

Return the facet that carries the run's "truth" for ordering / hub context:
the first C<hubs> entry when present, else the C<trace> facet, else an empty
hashref.

=back

=cut

sub hub_truth ($f) {
    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace}     if $f->{trace};
    return {};
}

=over 4

=item $path = share_dir()

Absolute path to the distribution's C<share/> directory, resolved relative to
this module's installed location. Croaks if the module is not found in C<%INC>.

=back

=cut

my $SHARE_DIR = do {
    # Resolve once at module load time, while cwd is still valid.  Calling
    # rel2abs lazily on the first share_dir() call gives the wrong answer when
    # the caller has chdir'd since loading this module.
    my $self_file = $INC{'Test2/Harness2/Util.pm'};
    if ($self_file) {
        my ($vol, $dir) = File::Spec->splitpath(File::Spec->rel2abs($self_file));
        my @parts = File::Spec->splitdir($dir);
        pop @parts while @parts && $parts[-1] eq '';
        splice(@parts, -3);    # drop Harness2, Test2, lib
        File::Spec->catdir(@parts, 'share');
    }
    else {
        undef;
    }
};

sub share_dir () {
    return $SHARE_DIR if $SHARE_DIR;
    # Fallback: module was not in %INC when loaded (should not happen in
    # normal use; here for safety so callers get an intelligible croak).
    my $self_file = $INC{'Test2/Harness2/Util.pm'} or croak "Util.pm not in %INC";
    my ($vol, $dir) = File::Spec->splitpath(File::Spec->rel2abs($self_file));
    my @parts = File::Spec->splitdir($dir);
    pop @parts while @parts && $parts[-1] eq '';
    splice(@parts, -3);    # drop Harness2, Test2, lib
    return $SHARE_DIR = File::Spec->catdir(@parts, 'share');
}

=pod

=over 4

=item $dt = now_dt()

Current UTC time as a L<DateTime> object at second precision. Pass directly
to QuickORM DATETIME columns; the DateTime autotype + dialect formatter
serialize it to SQLite's ISO-8601 form on insert.

=back

=cut

sub now_dt () { DateTime->now(time_zone => 'UTC') }

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
