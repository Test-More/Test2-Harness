package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness2::Util qw/open_file/;

use Object::HashBase qw{
    <file <absolute <relative
    <_scanned <_shbang
    <features <switches
    <category <duration <stage
    <conflicts
    <retry <retry_isolated
    <non_perl <is_binary
    <event_timeout <post_exit_timeout
    <min_slots <max_slots
    <meta
    <comment
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::TestFile';

sub init {
    my $self = shift;
    croak "'file' is required" unless defined $self->{+FILE};
    $self->{+ABSOLUTE} //= File::Spec->rel2abs($self->{+FILE});
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});

    # HashBase slot accessors shadow the role's default methods. Seed every
    # slot the role documents a default for so the accessor returns that
    # default instead of undef.
    my $defaults = $self->defaults;
    for my $k (keys %$defaults) {
        $self->{$k} //= $defaults->{$k};
    }
}

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return unless -e $self->{+ABSOLUTE};
    return if $self->{+IS_BINARY};

    my $comment = $self->{+COMMENT} // '#';

    my $fh = open_file($self->{+ABSOLUTE});
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        next if $line =~ m/^\s*$/;

        # Stage B will parse shebang here when $ln == 1.

        next if $line =~ m/^\s*\Q$comment\E/ && $line !~ m/^\s*\Q$comment\E\s*HARNESS-.+/;
        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;
        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        # Stages D-G will dispatch the matched directive here.
    }

    return;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
