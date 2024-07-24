package App::Yath::Options::Harness;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;
option_group {group => 'harness', category => 'Harness Options'} => sub {
    option dummy => (
        type           => 'Bool',
        short          => 'd',
        description    => 'Dummy run, do not actually execute anything',
        from_env_vars  => [qw/T2_HARNESS_DUMMY/],
        clear_env_vars => [qw/T2_HARNESS_DUMMY/],
        default        => 0,
    );

    option procname_prefix => (
        type        => 'Scalar',
        default     => 'yath',
        description => 'Add a prefix to all proc names (as seen by ps).',
        set_env_vars => [qw/T2_HARNESS_PROC_PREFIX/],
        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            if ($params{action} eq 'set') {
                my $val = $params{val} or return;
                my ($prefix) = @$val;

                $prefix .= "-yath" unless $prefix =~ m/(-|\b)yath(-|\b)/;

                $val->[0] = $prefix;
            }

            if ($params{action} eq 'clear') {
                $opt->add_value($params{ref}, 'yath');
            }
        }
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Harness - Options for any command that interacts with the harness API

=head1 DESCRIPTION

Options for any command that interacts with the harness API.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
