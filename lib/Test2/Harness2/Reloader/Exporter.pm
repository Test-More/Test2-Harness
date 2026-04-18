package Test2::Harness2::Reloader::Exporter;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/file2mod clean_path/;

# Optional-feature gate for the base reloader.
sub viable { 1 }

sub reload {
    my $class = shift;
    my ($file, $info) = @_;

    my $mod = $info->{module}
        or return (0, reason => "Reloader::Exporter requires a module name in file_info");

    # Snapshot every caller that imported from this module, with their
    # original args, from the active DepTracer (if any). The replay happens
    # after the module is re-required.
    my @replay;
    if (my $dt = _active_dep_tracer()) {
        my $targets = $dt->importers_of($mod);
        for my $target (@$targets) {
            my $args_list = $dt->import_args($mod, $target);
            push @replay => [$target, $_] for @$args_list;
        }
    }

    # Clear the stash so stale CV/glob references are replaced on reload.
    {
        no strict 'refs';
        my $stash = \%{"${mod}\::"};
        for my $sym (keys %$stash) {
            next if $sym =~ m/::$/;
            delete $stash->{$sym};
        }
    }

    delete $INC{$info->{inc_entry}} if $info->{inc_entry};
    delete $INC{$file};

    {
        local $.;
        require $file;
    }

    $INC{$file} //= $file;
    $INC{$info->{inc_entry}} //= $file if $info->{inc_entry};

    # Replay imports into every tracked caller so their aliased coderefs
    # point at the freshly-loaded subs. Errors during replay are warnings,
    # not fatals -- one bad caller should not stop the others.
    for my $entry (@replay) {
        my ($target, $args) = @$entry;
        # Append ";1;" so the eval value is truthy on success regardless of
        # what import() itself returns. Without it, an import that returns a
        # false value looks like an exception to the outer check.
        my $code = "package $target; $mod" . '->import(@{$args}); 1;';
        my $ok = eval $code;
        my $err = $@;
        warn "$$ $0 - Reloader::Exporter: replay import of '$mod' into '$target' failed: $err\n"
            unless $ok;
    }

    return (1);
}

sub _active_dep_tracer {
    return undef unless $INC{'Test2/Harness2/DepTracer.pm'};
    return Test2::Harness2::DepTracer->ACTIVE;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Exporter - In-place reload helper for
Exporter-style modules that keeps existing importers up to date.

=head1 DESCRIPTION

Plain stash-clear + re-require leaves imported coderefs stale. If
C<Pkg::A> did C<use Pkg::Source qw/foo/>, then C<*Pkg::A::foo> is an alias
to the C<Pkg::Source::foo> CV captured at import time. After reloading
C<Pkg::Source>, that alias still points at the old CV; C<Pkg::A::foo()>
calls the stale implementation.

This helper uses the L<Test2::Harness2::DepTracer>'s importer map
(populated by hooking C<Exporter::import>) to replay every recorded
C<import> call after the reload, so each caller's glob entries are
refreshed.

=head1 METHODS

=over 4

=item $bool = Test2::Harness2::Reloader::Exporter->viable

Always true at the moment. Reserved for future capability gating.

=item ($status, %fields) = Test2::Harness2::Reloader::Exporter->reload($file, $info)

Reload C<$file> (a path) using the module name from C<$info->{module}>.
Returns C<(1)> on success, or C<(0, reason =E<gt> $msg)> on failure.

=back

=head1 CAVEATS

=over 4

=item Custom importers

Modules that install a custom C<import> method (Moose, Sub::Exporter, etc.)
bypass the C<Exporter::import> hook in L<Test2::Harness2::DepTracer>. This
helper only replays what was recorded. Callers that came in through a
custom importer are on their own -- use L<Test2::Harness2::Reloader::Moose>
for Moose classes, or teach the custom importer to call
C<Test2::Harness2::DepTracer-E<gt>ACTIVE-E<gt>record_import> itself.

=item Order of replay

Callers are replayed in the order their target packages sort
alphabetically. If there are replay-order dependencies between two callers
(e.g. side effects of one C<import> affect another), the wrong caller may
end up with stale state. In practice this is rare.

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
