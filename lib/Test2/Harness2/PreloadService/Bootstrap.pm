package Test2::Harness2::PreloadService::Bootstrap;
use strict;
use warnings;

our $VERSION = '2.000011';

# Loaded at BEGIN time in a freshly exec'd preload-root process.
# ipcm_service(..., exec => { cmd => [...-MBootstrap=$cfg_file], stay_in_begin => 1 })
# places us at the front of the exec argv, so our import() runs before
# IPC::Manager::Service::State's import. That window is where we load
# the user's preload modules -- we want every configured module in
# %INC before the service loop starts serving launch_job requests.
#
# We intentionally keep this module tiny. The heavy lifting (spawning,
# state management, resource dance) lives on the harness side in
# Test2::Harness2::Resource::Preload and
# Test2::Harness2::PreloadService; this module is just the glue that
# runs during the exec'd child's compile phase.

sub import {
    my ($class, $config_file) = @_;

    return unless defined $config_file && length $config_file;

    require Test2::Harness2::Util::JSON;
    Test2::Harness2::Util::JSON->import(qw/decode_json/);

    open(my $fh, '<', $config_file)
        or die "PreloadService::Bootstrap: open '$config_file': $!";
    local $/;
    my $json = <$fh>;
    close($fh);

    my $config = decode_json($json);

    my $preloads = $config->{preload_modules} // [];

    # Plain-module preloads: require each module. A module that
    # consumes Test2::Harness2::Preload installs a TEST2_HARNESS_PRELOAD
    # marker sub; we leave the stage-tree merge to PreloadService
    # itself once it comes up (the meta-object is available as soon
    # as the module is loaded, so no extra work is needed here).
    for my $mod (@$preloads) {
        my $file = $mod;
        $file =~ s{::}{/}g;
        $file .= '.pm';

        my $ok = eval { require $file; 1 };
        next if $ok;
        die "PreloadService::Bootstrap: failed to load '$mod': $@";
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadService::Bootstrap - BEGIN-time preload loader
for the freshly exec'd preload-root process.

=head1 DESCRIPTION

L<Test2::Harness2::Resource::Preload> invokes C<ipcm_service> with an
C<exec + stay_in_begin> path, pointing the exec argv at this module
via C<-MTest2::Harness2::PreloadService::Bootstrap=$config_file>. Our
C<import> runs at compile time of the exec'd C<perl -e ...> (before
L<IPC::Manager::Service::State>'s C<import> takes over) and
C<require>s each module named in the config file.

The net effect: every preload module is present in C<%INC> by the
time L<IPC::Manager::Service::State> enters its service loop, so
every subsequent C<launch_job> forks a child that inherits the
preloaded state.

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
