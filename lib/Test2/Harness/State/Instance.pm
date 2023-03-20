package Test2::Harness::State::Instance;
use strict;
use warnings;

our $VERSION = '1.000152';

use parent 'Test2::Harness::IPC::SharedState';
use Test2::Harness::Util::HashBase(
    qw{
        <resources
        <job_count
        <settings
        <workdir
        <plugins
        <runs
        <ipc_model
    },
);


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::State::Instance - Data structure for yath shared state

=head1 DESCRIPTION

This is the primary shared state for all processes participating in a yath
instance.

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
