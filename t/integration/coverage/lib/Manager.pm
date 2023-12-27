package Manager;
use strict;
use warnings;

sub test_parameters {
    my $class = shift;
    my ($test, $coverage_data) = @_;

    my %seen;
    my @subtests;

    for my $set (values %$coverage_data) {
        for my $value (@$set) {
            next unless ref $value eq 'HASH';
            my $subtest = $value->{subtest} or next;
            next if $seen{$subtest}++;
            push @subtests => $subtest;
        }
    }

    return unless @subtests;

    @subtests = sort @subtests;

    return {
        run => 1,
        env => { COVER_TEST_SUBTESTS => join(", " => @subtests) },
        argv => \@subtests,
        stdin => join("\n" => @subtests) . "\n",
    };
}

1;
