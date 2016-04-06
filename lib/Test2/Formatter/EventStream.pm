package Test2::Formatter::EventStream;
use strict;
use warnings;

use Test2::Util::HashBase qw/handles/;
use base 'Test2::Formatter';
use Test2::Harness::Fact;

BEGIN {
    # We will cherry-pcik some things from it
    require Test2::Formatter::TAP;

    for my $s (qw/OUT_STD encoding/) {
        no strict 'refs';
        *{$s} = Test2::Formatter::TAP->can($s) or die "Could not steal $s from Test2::Formatter::TAP";
    }
}

use Carp qw/croak/;

Test2::Formatter::TAP::_autoflush(\*STDOUT);
Test2::Formatter::TAP::_autoflush(\*STDERR);

sub init {
    my $self = shift;

    $self->{+HANDLES} ||= $self->Test2::Formatter::TAP::_open_handles;
    if(my $enc = delete $self->{encoding}) {
        $self->encoding($enc);
    }

    my $fh = $self->{+HANDLES}->[+OUT_STD];
    print $fh "T2_FORMATTER: EventStream\n";
}

if ($^C) {
    no warnings 'redefine';
    *write = sub {};
}

sub write {
    my ($self, $e, $num) = @_;

    my $json = Test2::Harness::Fact->from_event($e, number => $num)->to_json;
    my $fh = $self->{+HANDLES}->[+OUT_STD];
    print $fh "T2_EVENT: $json\n";
}

sub hide_buffered { 0 }

1;
