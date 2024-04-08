package App::Yath::Command;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec;
use Carp qw/croak/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Util::HashBase qw/<settings <args <env_vars <option_state <plugins/;

sub args_include_tests { 0 }
sub internal_only      { 0 }
sub summary            { "No Summary" }
sub description        { "No Description" }
sub group              { "Z-FIXME" }

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub name { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }

sub run {
    my $self = shift;

    warn "This command is currently empty.\n";

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command - FIXME

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

