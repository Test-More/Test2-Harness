use Test2::V0;

__END__

package Test2::Harness::Runner::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness::Util::File::JSONL;

use parent 'Test2::Harness::Run';
use Test2::Harness::Util::HashBase qw{
    <workdir

    +queue
    >queue_ended
    +queue_pid

    +run_dir
    +jobs_file
    +jobs
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};
}

sub run_dir   { $_[0]->{+RUN_DIR}   //= $_[0]->SUPER::run_dir($_[0]->{+WORKDIR}) }
sub jobs_file { $_[0]->{+JOBS_FILE} //= File::Spec->catfile($_[0]->run_dir, 'jobs.jsonl') }
sub jobs      { $_[0]->{+JOBS}      //= Test2::Harness::Util::File::JSONL->new(name => $_[0]->jobs_file, use_write_lock => 1) }

sub _check_queue {
    my $self = shift;

    my $queue = $self->{+QUEUE} or return;

    return if $self->{+QUEUE_PID} && $self->{+QUEUE_PID} == $$;

    delete $self->{+QUEUE_ENDED};
    $queue->reset;
    $self->{+QUEUE_PID} = $$;
}

sub queue {
    my $self = shift;

    $self->_check_queue();

    return $self->{+QUEUE} if $self->{+QUEUE};

    $self->{+QUEUE_PID} = $$;
    return $self->{+QUEUE} = $self->SUPER::queue($self->run_dir);
}

sub queue_ended {
    my $self = shift;
    $self->_check_queue();
    return $self->{+QUEUE_ENDED};
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Run - Runner specific subclass of a test run.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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
