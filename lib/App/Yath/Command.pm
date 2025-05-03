package App::Yath::Command;
use strict;
use warnings;

our $VERSION = '2.000005';

use File::Spec;
use Carp qw/croak/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Util::HashBase qw/<settings <args <env_vars <option_state <plugins/;

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }
sub internal_only      { 0 }
sub summary            { "No Summary" }
sub description        { "No Description" }

sub cli_args { }
sub cli_dot  { }

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub name {
    my $class_or_self = shift;
    my $class = ref($class_or_self) || $class_or_self;

    if ($class =~ m/^App::Yath::Command::(.+)$/) {
        my $out = $1;
        $out =~ s/::/-/g;
        return $out;
    }

    return $class;
}

sub group {
    my $name = $_[0]->name;
    return if $_[0]->name =~ m/^(.+)-/;
    return 'Z-FIXME';
}

sub set_dot_args { croak "set_dot_args is not implemented" }

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


=pod

=cut POD NEEDS AUDIT

