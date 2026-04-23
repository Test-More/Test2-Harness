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

    # HashBase accessors shadow the role's default methods, so leaving a
    # slot undef would make the accessor return undef instead of the role
    # default.  Fill per-instance defaults here so callers get the
    # documented default when no value was supplied.
    $self->{+MIN_SLOTS}      //= 1;
    $self->{+CATEGORY}       //= 'general';
    $self->{+DURATION}       //= 'medium';
    $self->{+CONFLICTS}      //= [];
    $self->{+RETRY}          //= 0;
    $self->{+RETRY_ISOLATED} //= 0;
    $self->{+NON_PERL}       //= 0;
    $self->{+IS_BINARY}      //= 0;
    $self->{+SWITCHES}       //= [];
    $self->{+FEATURES}       //= {};
    $self->{+META}           //= {};
    $self->{+COMMENT}        //= '#';
}

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;    # sets flag on first pass
    return unless -e $self->{+ABSOLUTE};
    return if $self->{+IS_BINARY};

    my $comment = $self->{+COMMENT} // '#';

    my $fh = open_file($self->{+ABSOLUTE});
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        next if $line =~ m/^\s*$/;

        if ($ln == 1) {
            # Stage B: shebang parsing placeholder
        }

        next if $line =~ m/^\s*\Q$comment\E/ && $line !~ m/^\s*\Q$comment\E\s*HARNESS-.+/;

        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;

        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        # Stage D-G: directive dispatch placeholder
    }
}

1;

__END__

=head1 POD IS AUTO-GENERATED
