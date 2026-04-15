package Test2::Harness2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Errno qw/ESRCH/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    pid_is_running
    set_procname
    swap_io
};

sub pid_is_running {
    my ($pid) = @_;

    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);    # Running and we have perms
    return 0 if $! == ESRCH;      # Does not exist (not running)
    return -1;                    # Running, but not ours
}

sub set_procname {
    my %params = @_;

    my $prefix = $params{prefix} // $ENV{T2_HARNESS2_PROC_PREFIX} // 'Test2-Harness2';
    my $append = $params{append} // [];
    my $set    = $params{set}    // [];

    $append = [$append] unless ref($append);
    $set    = [$set]    unless ref($set);

    my $name = join('-', (@$set ? @$set : $0), @$append);

    $name = "${prefix}-${name}" unless $name =~ m/^\Q$prefix\E-/;

    $0 = $name;
}

sub swap_io {
    my ($fh, $to) = @_;

    my $orig_fd = fileno($fh);
    croak "Could not get fd for handle" unless defined $orig_fd;

    open($fh, '>&', $to) or croak "Could not redirect fd $orig_fd: $!";

    croak "Handle does not have the expected fd (got " . fileno($fh) . ", wanted $orig_fd)"
        if fileno($fh) != $orig_fd;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::IPC - Small IPC-related helpers shared across the harness.

=head1 DESCRIPTION

A handful of low-level utilities used by the collector and other harness
processes for cross-process work.

=head1 SYNOPSIS

    use Test2::Harness2::Util::IPC qw/pid_is_running set_procname swap_io/;

    # Liveness check for a pid we may or may not own.
    if (my $rc = pid_is_running($child_pid)) {
        # 1  -> running and we own it
        # -1 -> running but owned by someone else
    }

    # Annotate $0 so 'ps' shows what this process is doing.
    set_procname(set => ['Collector', $child_pid]);
    set_procname(append => ['draining']);

    # Redirect a known fd onto another handle, preserving the fd number.
    open(my $log, '>>', '/tmp/out.log') or die $!;
    swap_io(\*STDOUT, $log);

=head1 EXPORTS

=over 4

=item $bool_or_neg = pid_is_running($pid)

Returns C<1> if C<$pid> is running and we own it, C<0> if it is gone, and
C<-1> if it is running but owned by someone else.

=item set_procname(%params)

Sets C<$0> with an optional C<prefix> (default C<Test2-Harness>, overridable
via the C<T2_HARNESS_PROC_PREFIX> env var). Pass C<set =E<gt> [...]> to
replace the body, or C<append =E<gt> [...]> to append to the current C<$0>.

=item swap_io($fh, $to)

Reopens C<$fh> as a duplicate of C<$to> while preserving its file descriptor
number. Croaks if the resulting fd does not match.

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
