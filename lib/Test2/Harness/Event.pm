package Test2::Harness::Event;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Importer 'Test2::Util::Facets2Legacy' => ':ALL';

BEGIN {
    require Test2::Event;
    our @ISA = ('Test2::Event');

    # Currently the base class for events does not have init(), that may change
    if (Test2::Event->can('init')) {
        *INIT_EVENT = sub() { 1 }
    }
    else {
        *INIT_EVENT = sub() { 0 }
    }
}

use Test2::Harness::Util::HashBase qw{
    <facet_data
    <stream_id
    <event_id
    <run_id
    <job_id
    <stamp
    <times
    +json
    processed
};

sub trace     { $_[0]->{+FACET_DATA}->{trace} }
sub set_trace { confess "'trace' is a read only attribute" }

sub init {
    my $self = shift;

    $self->Test2::Event::init() if INIT_EVENT;

    my $data = $self->{+FACET_DATA} || confess "'facet_data' is a required attribute";

    for my $field (RUN_ID(), JOB_ID(), EVENT_ID) {
        my $v1 = $self->{$field};
        my $v2 = $data->{harness}->{$field};

        my $d1 = defined($v1);
        my $d2 = defined($v2);

        confess "'$field' is a required attribute" unless $d1 || $d2;
        confess "'$field' has different values between attribute and facet data"
            if $d1 && $d2 && $v1 ne $v2;

        $self->{$field} = $data->{harness}->{$field} = $v1 // $v2;
    }

    delete $data->{facet_data};

    # Original trace wins.
    if (my $trace = delete $self->{+TRACE}) {
        $self->{+FACET_DATA}->{trace} //= $trace;
    }
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $out = {%{$_[0]}};

    $out->{+FACET_DATA} = { %{$out->{+FACET_DATA}} };
    delete $out->{+FACET_DATA}->{harness_job_watcher};
    delete $out->{+FACET_DATA}->{harness}->{closed_by};
    delete $out->{+JSON};
    delete $out->{+PROCESSED};

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Event - Subclass of Test2::Event used by Test2::Harness under
the hood.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
