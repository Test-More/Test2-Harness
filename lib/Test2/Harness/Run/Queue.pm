package Test2::Harness::Run::Queue;
use strict;
use warnings;

our $VERSION = '0.001077';

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

    return $self->{+ENDED} if $self->{+ENDED};

    $self->{+QH} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
    my @out = $self->{+QH}->poll_with_index();

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

Test2::Harness::Run::Queue - Logic for a runner queue

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
