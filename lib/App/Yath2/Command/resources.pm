package App::Yath2::Command::resources;
use strict;
use warnings;

our $VERSION = '2.000011';

use App::Yath2::Daemon;

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath resources`: dump the resource table the daemon knows about.
sub run {
    my $self = shift;

    my %opts;
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath resources: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath resources: cannot attach to daemon: $@";
        return 2;
    }

    my $res = eval { $spawn->list_resources };
    unless (ref($res) eq 'HASH' && $res->{ok}) {
        print STDERR "yath resources: list_resources failed: ",
            (ref($res) eq 'HASH' ? ($res->{error} // '(no error)') : ($@ // '(no response)')),
            "\n";
        return 1;
    }

    my @entries = @{$res->{resources} // []};
    unless (@entries) {
        print "No resources attached.\n";
        return 0;
    }

    for my $r (@entries) {
        my $tags = join(',',
            ($r->{is_usable}           ? () : 'unusable'),
            ($r->{is_broken}           ? 'broken'           : ()),
            ($r->{is_permanent_broken} ? 'permanent_broken' : ()),
            ($r->{is_paused}           ? 'paused'           : ()),
        );
        $tags ||= 'usable';

        my $scope_hdr = $r->{scope} eq 'run' && $r->{run_id}
            ? "run $r->{run_id}"
            : 'global';

        print "[$scope_hdr] $r->{resource_name} ($r->{class}) -- $tags\n";
        my $status = $r->{status} // {};
        if (ref($status) eq 'HASH' && keys %$status) {
            for my $k (sort keys %$status) {
                my $v = $status->{$k};
                $v = ref($v) ? '(ref)' : (defined $v ? $v : '(undef)');
                print "    $k: $v\n";
            }
        }
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::resources - Inspect the daemon's resource state.

=head1 DESCRIPTION

Prints one entry per resource attached to the daemon (global and
per-run scope), with the resource's class, a status tag
(usable / broken / permanent_broken / paused / unusable), and any
fields the resource's C<status> method returns.

=cut
