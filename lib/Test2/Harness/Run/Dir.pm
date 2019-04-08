package Test2::Harness::Run::Dir;
use strict;
use warnings;

our $VERSION = '0.001073';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util::File::Stream;

use Test2::Harness::Util::HashBase qw/-root -_jobs_file -_err_file -_log_file -tail/;

sub init {
    my $self = shift;

    croak "The 'root' attribute is required"
        unless $self->{+ROOT};

    $self->{+ROOT} = File::Spec->rel2abs($self->{+ROOT});
}

sub log_file {
    my $self = shift;
    return $self->{+_LOG_FILE} ||= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+ROOT}, 'output.log'),
        tail => $self->{+TAIL},
    );
}

sub err_file {
    my $self = shift;
    return $self->{+_ERR_FILE} ||= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+ROOT}, 'error.log'),
        tail => $self->{+TAIL},
    );
}

sub jobs_file {
    my $self = shift;
    return $self->{+_JOBS_FILE} ||= Test2::Harness::Util::File::JSONL->new(
        name => File::Spec->catfile($self->{+ROOT}, 'jobs.jsonl'),
    );
}

sub err_list { $_[0]->err_file->poll(from => 0) }
sub err_poll { $_[0]->err_file->poll(max  => $_[1]) }

sub log_list { $_[0]->log_file->poll(from => 0) }
sub log_poll { $_[0]->log_file->poll(max  => $_[1]) }

sub job_list { map { Test2::Harness::Job->new(%{$_}) } $_[0]->jobs_file->poll(from => 0) }
sub job_poll { map { Test2::Harness::Job->new(%{$_}) } $_[0]->jobs_file->poll(max => $_[1])}

sub complete { -e File::Spec->catfile($_[0]->{+ROOT}, 'complete') }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run::Dir - Class to handle a directory for an active test run.

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
