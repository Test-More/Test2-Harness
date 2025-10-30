package Test2::Harness::Util::Scrubber;

use strict;
use warnings;

sub scrub_facet_data {
    my ($facet) = @_;

    # Scan for non-printing chars and scrub them if they aren't newlines.
    if( exists($facet->{'assert'}) && $facet->{'assert'}{'details'} ) {
        $facet->{'assert'}{'details'} =~ s/[^\n[:print:]]//g;
    }
    if( exists($facet->{'info'}) && ref $facet->{'info'} eq 'ARRAY' ) {
        $_->{'details'} =~ s/[^\n[:print:]]//g for @{ $facet->{'info'} };
    }
    if( exists($facet->{'trace'}) && ref $facet->{'trace'}{'full_caller'} eq 'ARRAY' ) {
        for ( @{ $facet->{'trace'}{'full_caller'} } ) {
            $_ =~ s/[^\n[:print:]]//g if length $_;
        }
    }
    if( exists $facet->{'meta'} && exists $facet->{'meta'}{'Test::Builder'} && exists $facet->{'meta'}{'Test::Builder'}{'name'} && length $facet->{'meta'}{'Test::Builder'}{'name'} ) {
        $facet->{'meta'}{'Test::Builder'}{'name'} =~ s/[^\n[:print:]]//g;
    }

    return;
}

1;

__END__

=head1 NAME

Test2::Harness::Util::Scrubber

=head2 DESCRIPTION

Module for scrubbing NULs from facet data (and any other non-printing chars).

You may be asking "WHY," and it's a good question.
PosgreSQL servers past 9.4 don't tolerate NULs, but plenty of tests emit NULs.
Since it's not something users can see anyways, we may as well scrub it regardless of reporting
destination along with other nonprinting characters.

This module may not last forever, as honestly this is more of a band-aid than anything.

Ideally this should land somewhere in the guts of our PG related logic, but I haven't quite
found the right place to intercept these events and comprehensively scrub them before send.

Probably just something I'm missing regarding our usage of the DBIX::Class ORM here.

=cut
