package App::Yath::Renderer;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak carp/;

use Test2::Harness::Util::HashBase qw{
    <color
    <hide_runner_output
    <progress
    <quiet
    <show_times
    <term_width
    <truncate_runner_output
    <verbose
    <wrap
    <interactive
    <is_persistent
    <show_job_end
    <show_job_info
    <show_job_launch
    <show_run_info
    <show_run_fields
    <settings
    <theme
};

sub init {
    my $self = shift;

    croak "'settings' is required" unless $self->{+SETTINGS};
}

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub start  { }
sub step   { }
sub signal { }
sub finish { }

sub exit_hook {}

sub weight { 0 }

sub end_of_events { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

