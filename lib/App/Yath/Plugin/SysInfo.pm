package App::Yath::Plugin::SysInfo;
use strict;
use warnings;

our $VERSION = '2.000005';

use Sys::Hostname qw/hostname/;
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
use Config qw/%Config/;

use parent 'App::Yath::Plugin';
use Test2::Harness::Util::HashBase qw/-host_short_pattern/;

use Getopt::Yath;
option_group {prefix => 'sysinfo', group => 'sysinfo', category => "SysInfo Options"} => sub {
    option 'sysinfo' => (
        type => 'Bool',
        prefix => undef,
        description => "Enable the SysInfo plugin",
    );
};

sub run_fields {
    my $self = shift;

    my %data = (
        env => {
            user  => $ENV{USER},
            shell => $ENV{SHELL},
            term  => $ENV{TERM},
            (map { m/(YATH|T2|TEST2|HARNESS|PERL|CPAN|TAP)/i ? ($_ => $ENV{$_}) : ()} keys %ENV),
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

        if (my $pattern = $self->{+HOST_SHORT_PATTERN}) {
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

sub run_queued {
    my $self = shift;
    my ($run) = @_;

    my @fields = $self->run_fields;
    return unless @fields;

    $run->send_event(facet_data => {harness_run_fields => \@fields});
}

sub TO_JSON { ref($_[0]) }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::SysInfo - Plugin to attach system information to a run.

=head1 DESCRIPTION

This plugin attaches a lot of system information to the yath log. This is most
useful when using a database or server.

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

=pod

=cut POD NEEDS AUDIT

