package App::Yath::Options::Collector;
use strict;
use warnings;

our $VERSION = '1.000039';

use App::Yath::Options;

option_group {prefix => 'collector', category => "Collector Options"} => sub {
    option max_jobs_to_process => (
        description => 'The maximum number of jobs that the collector can process each loop (Default: 300)',
        default => 300,
    );
};

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Collector - collector options for Yath.

=head1 DESCRIPTION

This is where the command line options for the collector are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
