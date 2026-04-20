package App::Yath2::Command::init;
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

# `yath init` creates an empty project-root .yath.rc so subsequent
# yath invocations can find it. This stage ships a deliberately
# minimal version: the full init flow (scaffolding a directory
# structure, writing a curated .yath.rc with common defaults) lands
# when a consumer actually needs it. Here we just check that no
# .yath.rc exists, create one with a V2 marker line, and exit.
sub run {
    my $self = shift;

    my $path = '.yath.rc';

    if (-f $path) {
        print STDERR "yath init: '$path' already exists; refusing to overwrite.\n";
        return 1;
    }

    open(my $fh, '>', $path) or do {
        print STDERR "yath init: open '$path': $!\n";
        return 2;
    };
    print $fh "# V2\n";
    close($fh) or do {
        print STDERR "yath init: close '$path': $!\n";
        return 2;
    };

    print "Created $path\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::init - Scaffold a minimal project-root
C<.yath.rc>.

=head1 DESCRIPTION

Stage 13 ships a minimum viable init: creates an empty
C<.yath.rc> with a single C<# V2> marker line so later yath
invocations recognise the project as 2.0-configured. The full
init flow (scaffolding directories, writing curated defaults)
lands when a consumer actually needs it.

=cut
