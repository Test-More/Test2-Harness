package Test2::Harness::Util::Queue;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Util::File::JSONL();

use Test2::Harness::Util::HashBase qw{
    -file -qh -ended
};

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};
}

sub start {
    my $self = shift;
    write_file_atomic($self->{+FILE}, "");
}

sub seek {
    my $self = shift;
    my ($pos) = @_;

    $self->{+QH} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
    $self->{+QH}->seek($pos);

    return $pos;
}

sub reset {
    my $self = shift;
    delete $self->{+QH};
}

sub poll {
    my $self = shift;
    my $max = shift;

    return $self->{+ENDED} if $self->{+ENDED};

    $self->{+QH} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
    my @out = $self->{+QH}->poll_with_index( $max ? (max => $max) : () );

    $self->{+ENDED} = $out[-1] if @out && !defined($out[-1]->[-1]);

    return @out;
}

sub end {
    my $self = shift;
    $self->_enqueue(undef);
}

sub enqueue {
    my $self = shift;
    my ($task) = @_;

    croak "Invalid task"
        unless $task && ref($task) eq 'HASH' && values %$task;

    $task->{stamp} ||= time;

    $self->_enqueue($task);
}

sub _enqueue {
    my $self = shift;
    my ($task) = @_;

    my $fh = Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE}, use_write_lock => 1);
    $fh->write($task);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::Queue - Representation of a queue.

=head1 DESCRIPTION

This module represents a queue, stored as a jsonl file.

=head1 SYNOPSIS

    use Test2::Harness::Util::Queue;

    my $queue = Test2::Harness::Util::Queue->new(file => '/path/to/queue.jsonl');

    $queue->start(); # Create the queue

    $queue->enqueue({foo => 'bar', baz => 'bat'});
    $queue->enqueue({foo => 'bar2', baz => 'bat2'});
    ...

    $queue->end();

Then in another processs:

    use Test2::Harness::Util::Queue;

    my $queue = Test2::Harness::Util::Queue->new(file => '/path/to/queue.jsonl');

    my @items;
    while (1) {
        @items = $queue->poll();
        while (@items) {
            my $item = shift @items or last;

            ... process $item
        }

        # Queue ends with an 'undef' entry
        last if @items && !defined($items[0]);
    }

=head1 METHODS

=over 4

=item $path = $queue->file

The filename used for the queue

=back

=head2 READING

=over 4

=item $queue->reset()

Restart reading the queue.

=item @items = $queue->poll()

Get more items from the queue. May need to call it multiple times, specially if
another process is still writing to the queue.

Returns an empty list if no items are available yet.

Returns 'undef' to terminate the list.

=item $bool = $queue->ended()

Check if the queue has ended.

=back

=head1 WRITING

=over 4

=item $queue->start()

Open the queue file for writing.

=item $queue->enqueue(\%HASHREF)

Add an item to the queue.

=item $queue->end()

Terminate the queue.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
