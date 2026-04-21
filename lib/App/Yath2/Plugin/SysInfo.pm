package App::Yath2::Plugin::SysInfo;
use strict;
use warnings;

our $VERSION = '2.000011';

use Sys::Hostname qw/hostname/;
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
use Config qw/%Config/;

use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';

use Object::HashBase qw{-host_short_pattern};

use Getopt::Yath;
option_group {prefix => 'sysinfo', group => 'sysinfo', category => "SysInfo Options"} => sub {
    option 'sysinfo' => (
        type        => 'Bool',
        prefix      => undef,
        description => "Enable the SysInfo plugin",
    );
};

# Build the one-and-only run field this plugin contributes. Captures
# the current process's view of the host:
#
#   env     -- selected env vars (USER/SHELL/TERM plus anything
#              whose name matches YATH / T2 / TEST2 / HARNESS /
#              PERL / CPAN / TAP so rerun / replay can reproduce
#              the env at launch).
#   ipc     -- the five CAN_* bits from Test2::Util, so downstream
#              consumers can tell whether the host has true fork/
#              thread support versus emulation.
#   hostname + short  -- full hostname plus a short display form.
#                        If the plugin is instantiated with a
#                        host_short_pattern arg, the first regex
#                        capture is the short form. Otherwise the
#                        hostname is truncated from the right one
#                        dotted segment at a time until it fits in
#                        <= 18 chars.
#   config  -- a handful of @Config keys that shape binary
#              compatibility (use64bit*, ithreads, perlio, ...).
sub run_fields {
    my $self = shift;

    my %data = (
        env => {
            user  => $ENV{USER},
            shell => $ENV{SHELL},
            term  => $ENV{TERM},
            (map { m/(YATH|T2|TEST2|HARNESS|PERL|CPAN|TAP)/i ? ($_ => $ENV{$_}) : () } keys %ENV),
        },

        ipc => {
            can_fork        => CAN_FORK(),
            can_really_fork => CAN_REALLY_FORK(),
            can_thread      => CAN_THREAD(),
            can_sigsys      => CAN_SIGSYS(),
        },
    );

    my ($short, $raw) = ('sys', 'system info');

    if (my $hostname = hostname()) {
        $short          = undef;
        $data{hostname} = $hostname;
        $raw            = $hostname;

        if (my $pattern = ref($self) ? $self->{+HOST_SHORT_PATTERN} : undef) {
            if ($hostname =~ /($pattern)/) {
                $short = $1;
            }
        }

        unless ($short) {
            $short = $hostname;
            $short =~ s/\.[^\.]*$// while length($short) > 18 && $short =~ m/\./;
        }
    }

    my @fields = qw/uselongdouble use64bitall version use64bitint usemultiplicity osname useperlio useithreads archname/;
    @{$data{config}}{@fields} = @Config{@fields};

    return ({
        name    => 'sys',
        details => $short,
        raw     => $raw,
        data    => \%data,
    });
}

# Dispatched by Test2::Harness2 when a run is queued. Return the
# run-field record so the harness can stamp it onto the run.
sub run_queued {
    my $self = shift;
    my ($run) = @_;

    return $self->run_fields;
}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::SysInfo - Plugin to attach system information to a run.

=head1 DESCRIPTION

This plugin attaches system information (hostname, env, perl config,
fork/thread capabilities) to a run's metadata. Enabled with C<-pSysInfo>
or C<--plugin=SysInfo>.

The metadata shows up under the run's C<fields> list as a record
with C<< name => 'sys' >>.

=head1 SYNOPSIS

    $ yath test -pSysInfo ...

=head1 OPTIONS

See C<< yath help sysinfo >> for the SysInfo option group (currently
just C<--sysinfo> to enable the plugin when its class name alone
isn't enough).

=head1 CONSTRUCTOR ARGUMENTS

=over 4

=item host_short_pattern => $regex_string

Optional regex. When set, the first capture group is used as the
C<short> form of the hostname. Without a pattern the hostname is
truncated one dotted segment at a time from the right until it
fits in 18 characters.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
