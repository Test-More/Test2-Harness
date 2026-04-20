package App::Yath2::Command::list;
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

# `yath list PATH...` prints one line per test file the finder would
# expand each PATH argument into. Useful for scripting and for the
# ported old/t/Yath/integration tests that exercise finder behaviour
# without actually running the tests.
sub run {
    my $self = shift;

    my $argv = [@{$self->argv}];

    # Strip any --option args for this stage -- the finder honours
    # simple positional arguments only. A later revision will layer
    # include_options('App::Yath2::Options::Finder') over this path
    # the same way Command::test does for its options.
    my @paths = grep { !/^-/ } @$argv;

    unless (@paths) {
        print STDERR "yath list: no paths given\n";
        print STDERR "Usage: yath list FILE|DIRECTORY [...]\n";
        return 2;
    }

    require App::Yath2::Finder::Simple;
    my @tests = App::Yath2::Finder::Simple->find(@paths);

    unless (@tests) {
        print STDERR "yath list: no test files discovered under given paths\n";
        return 1;
    }

    # Finder returns App::Yath2::TestFile objects; print the
    # human-readable relative path so the output is usable both as
    # a status list and as input to shell commands.
    for my $tf (@tests) {
        my $path = $tf->can('relative') ? $tf->relative : $tf->file;
        print "$path\n";
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::list - List the test files a finder would
expand a path into.

=head1 DESCRIPTION

Stage 13 port. Walks each positional argument through
L<App::Yath2::Finder::Simple> and prints the resulting test file
paths, one per line, to STDOUT.

Options the finder itself supports (e.g. C<--ext=tx>) are deferred
to a later revision that layers
C<include_options('App::Yath2::Options::Finder')> over this
command.

=cut
