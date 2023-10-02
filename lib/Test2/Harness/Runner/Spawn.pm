package Test2::Harness::Runner::Spawn;
use strict;
use warnings;

our $VERSION = '1.000155';

use parent 'Test2::Harness::Runner::Job';
use Test2::Harness::Util::HashBase;

sub init {
    my $self = shift;

    $self->{+RUN} //= Test2::Harness::Runner::Spawn::Run->new();
}

sub out_file { sprintf('/proc/%i/fd/1', $_[0]->{+TASK}->{owner}) }
sub err_file { sprintf('/proc/%i/fd/2', $_[0]->{+TASK}->{owner}) }
sub in_file  { undef }

sub args { @{$_[0]->{+TASK}->{args} //= []} }

sub job_dir { "" }
sub run_dir { "" }

sub use_stream   { 0 }
sub event_uuids  { 0 }
sub mem_usage    { 0 }
sub io_events    { 0 }

# These return lists
sub load_import { }
sub load        { }

package Test2::Harness::Runner::Spawn::Run;

sub new { bless {}, shift };

sub env_vars { {} }

sub AUTOLOAD { }

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Spawn - Minimal job class used for spawning processes

=head1 DESCRIPTION

Do not use this directly...

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
