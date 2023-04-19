package App::Yath::Command::aggregator;
use strict;
use warnings;

use Test2::Harness::Aggregator;
use Test2::Harness::State;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

our $VERSION = '2.000000';

sub name          { 'aggregator' }
sub group         { 'z_internal' }
sub summary       { "Start an aggregator process" }
sub internal_only { 1 }

sub description {
    return <<"    EOT";
An aggregator process takes events from any number of sources and combines them
into a single output stream.
    EOT
}

sub run {
    my $self = shift;
    my ($name, $state_file, $fifo_file, $output_file, $parent_pid) = @{$self->{+ARGS}};

    my $state = Test2::Harness::State->new(state_file => $state_file);

    my $aggregator = Test2::Harness::Aggregator->new(
        name        => $name,
        state       => $state,
        fifo_file   => $fifo_file,
        output_file => $output_file,
    );

    return $aggregator->run($parent_pid);
}

1;

__END__

=head1 POD IS AUTO-GENERATED

