package Test2::Harness::Run::Queue;
use strict;
use warnings;

our $VERSION = '0.001005';

use Carp qw/croak/;

use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::File::JSONL();

use Test2::Harness::Util::HashBase qw{
    -file -qh
    -index_file
};

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    my $index_file = $self->{+FILE};
    $index_file =~ s/\.jsonl/_index/;
    $self->{+INDEX_FILE} ||= $index_file;
}

sub mark {
    my $self = shift;
    my ($job_id, $jobs, $last_item) = @_;

    my $pos = $last_item->[1];

    my $index_file = Test2::Harness::Util::File::JSON->new(name => $self->{+INDEX_FILE});
    $index_file->write({pos => $pos, job_id => $job_id, jobs => $jobs});
}

sub create_or_recall {
    my $self = shift;

    if (-f $self->{+INDEX_FILE}) {
        die "Have index file, but no queue file!"
            unless -f $self->{+FILE};

        my $index_file = Test2::Harness::Util::File::JSON->new(name => $self->{+INDEX_FILE});
        my $data = $index_file->read;

        $self->{+QH} = Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
        $self->{+QH}->seek($data->{pos});

        return ($data->{job_id}, %{$data->{jobs}});
    }

    write_file_atomic($self->{+FILE}, "");
    $self->{+QH} = Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
    $self->{+QH}->seek(0);
    return (1,);
}

sub poll {
    my $self = shift;
    $self->{+QH} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE});
    $self->{+QH}->poll_with_index();
}

sub respawn {
    my $self = shift;
    my $fh = Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE}, use_write_lock => 1);
    $fh->write({respawn => 1});
}

sub end_queue {
    my $self = shift;
    my $fh = Test2::Harness::Util::File::JSONL->new(name => $self->{+FILE}, use_write_lock => 1);
    $fh->write({end_queue => 1});
}

sub enqueue {
    my $self = shift;
    my ($task) = @_;

    croak "You cannot queue anything with the 'end_queue' hash key" if $task->{end_queue};
    croak "You cannot queue anything with the 'respawn' hash key"   if $task->{respawn};

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
