package App::Yath2::Command::failed;
use strict;
use warnings;

our $VERSION = '2.000011';

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

# `yath failed` re-runs the tests that failed in the most recent
# run. Stage 13 stubs this deliberately: reading a prior run's
# results requires the Stage 12 artifact-reading layer (and a
# "most recent workdir" discovery mechanism, likely tied to
# $workdir or ~/.yath-last-run). Both are deferred.
sub run {
    my $self = shift;

    print STDERR "yath failed: not yet implemented in this rewrite.\n";
    print STDERR "This command depends on Stage 12's artifact-reading layer;\n";
    print STDERR "see PLAN for the port order.\n";

    return 2;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::failed - Re-run tests that failed in the
most recent run. (Stub.)

=head1 STATUS

Stubbed in Stage 13. Landing requires Stage 12's artifact-reading
layer plus a last-run-workdir discovery path; both are explicit
follow-ups in PLAN.

=cut
