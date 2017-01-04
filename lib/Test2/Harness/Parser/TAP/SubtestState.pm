package Test2::Harness::Parser::TAP::SubtestState;
use strict;
use warnings;

our $VERSION = '0.000014';

use Carp qw/confess/;
use Test2::Util::HashBase qw/_subtest_id _last_id _state/;

sub init {
    my $self = shift;
    $self->{+_SUBTEST_ID} = 'A';
    $self->{+_LAST_ID} = '';
    $self->{+_STATE} = [];
}

sub maybe_start_streaming_subtest {
    my $self = shift;
    my ($e) = @_;

    my $nest = $e->nested || 0;
    return $e unless $nest > 0;

    my $id;

    if ($e->in_subtest) {
        confess(
            sprintf(
                'Got a %s object already in a subtest (ID = %s) that might start a streaming subtest',
                ref $e,
                $e->in_subtest
            )
        );
    }

    # We will see a Test2::Event::Subtest event object when we finish a
    # streaming subtest. We don't want that event to trigger the start of a
    # new streaming subtest. Instead, that subtest needs to be added to
    # subevents of a parent subtest, if one exists.
    if ($e->isa('Test2::Event::Subtest') && $e->subtest_id eq $self->{+_LAST_ID}) {
        return $e unless $nest > 0;
        $nest--;
        # The subtest itself is at the nesting level of its parent (another
        # subtest or the main test).
        $e->set_nested($nest);
        return $e unless $self->{+_STATE}[$nest];
    }

    if ($self->{+_STATE}[$nest])    {
        $id = $self->{+_STATE}[$nest]{id};
    }
    else {
        $id = $self->next_id;
        $self->{+_STATE}[$nest] = {
            id        => $id,
            subevents => [],
        };
    }

    push @{$self->{+_STATE}[$nest]{subevents}}, $e;

    $e->set_in_subtest($id);

    return $e;
}

sub finish_streaming_subtest {
    my $self = shift;
    my ($pass, $name, $nest) = @_;

    # The ok event that ends a streaming subtest is one nesting level lower
    # than the events that make up the subtest.
    $nest = ($nest || 0) + 1;
    unless ($self->{+_STATE}[$nest]) {
        confess "Cannot find any subtest state at nesting level $nest to finish!";
    }

    my $max = $#{$self->{+_STATE}};
    if ($max > $nest) {
        confess "Ending a subtest at nesting level $nest but there are still subtests in-process up to level $max!";
    }

    my $state = pop @{$self->{+_STATE}};
    $self->{+_LAST_ID} = $state->{id};

    return (
        pass       => $pass,
        name       => $name,
        nested     => $nest,
        subtest_id => $state->{id},
        subevents  => $state->{subevents},
    );
}

sub next_id {
    my $self = shift;
    return $self->{+_SUBTEST_ID}++;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Parser::TAP::SubtestState - An object used by the TAP stream parser to help handle subtests

=head1 DESCRIPTION

There are no user-serviceable parts here. This class is used by
L<Test2::Harness::Parser::TAP> to handle some bookkeeping around streaming
subtests.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
