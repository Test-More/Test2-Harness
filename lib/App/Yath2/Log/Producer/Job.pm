package App::Yath2::Log::Producer::Job;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Log::Producer';

use Object::HashBase qw{
    <try
    <pass
    <report_available
};

sub init {
    my $self = shift;
    $self->{+App::Yath2::Log::Producer::KIND} //= 'job';
    $self->SUPER::init();
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Producer::Job - Job producer descriptor.

=head1 DESCRIPTION

Extends L<App::Yath2::Log::Producer> with job-specific fields: C<try>,
C<pass>, and C<report_available>. Defaults C<kind> to C<'job'>.

C<try> is an integer indicating which attempt this job represents (zero-based).
C<pass> is a boolean (or C<undef> when not yet known) indicating whether the
job passed. C<report_available> is a boolean indicating whether a TAP or
structured report is available for this job.

Note that C<job_id> is an alias for the base class C<id> field; no separate
accessor is provided.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
