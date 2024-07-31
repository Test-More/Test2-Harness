package App::Yath::Options::WebClient;
use strict;
use warnings;

our $VERSION = '2.000002';

use Getopt::Yath;

option_group {group => 'webclient', category => "Web Client Options"} => sub {
    option url => (
        type => 'Scalar',
        alt => ['uri'],
        description => "Yath server url",
        long_examples  => [" http://my-yath-server.com/..."],
        from_env_vars => [qw/YATH_URL/],
    );

    option api_key => (
        type => 'Scalar',
        description => "Yath server API key. This is not necessary if your Yath server instance is set to single-user",
        from_env_vars => [qw/YATH_API_KEY/],
    );

    option grace => (
        type => 'Bool',
        description => "If yath cannot connect to a server it normally throws an error, use this to make it fail gracefully. You get a warning, but things keep going.",
        default => 0,
    );

    option request_retry => (
        type => 'Count',
        description => "How many times to try an operation before giving up",
        default => 0,
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::WebClient - FIXME

=head1 DESCRIPTION

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

