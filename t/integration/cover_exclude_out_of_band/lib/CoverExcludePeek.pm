package CoverExcludePeek;
use strict;
use warnings;

use parent 'App::Yath::Plugin';

sub handle_event {
    my $self = shift;
    my ($e, $settings) = @_;

    my $coverage = $e->{facet_data}->{coverage} or return;

    print "COVERAGE FACET: files=" . (ref($coverage->{files}) || 'SCALAR') . " file_count=" . ($coverage->{file_count} // 'undef') . "\n";

    return;
}

1;
