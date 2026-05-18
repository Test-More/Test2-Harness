package App::Yath2::Log::Live;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Log::Directory';

# Live workdir variant of the Directory backend. Forces live=1 on the
# underlying directory backend so the iterator polls (rather than
# treating EOF as terminal) and treats artifact termination as
# "matching harness_collector_end has been observed in the parent".
#
# Note: do NOT re-apply App::Yath2::Role::Log here. Directory already
# does, and re-applying installs the role's default sub stubs into our
# package, shadowing Directory's real implementations (e.g.
# _open_artifact_for_producer) via Perl's method resolution.

sub init {
    my $self = shift;
    $self->{+App::Yath2::Log::Directory::LIVE} = 1;
    $self->SUPER::init;
}

sub is_live { 1 }
sub static  { 0 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Live - Live-workdir Log reader.

=head1 DESCRIPTION

Subclass of L<App::Yath2::Log::Directory> that forces C<live=1>.
Used by callers that want to iterate a still-running harness's log
directory and have the iterator's EOE / next-record semantics reflect
the live nature of the source.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
