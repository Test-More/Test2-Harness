package Test2::Harness::UI;
use strict;
use warnings;

our $VERSION = '0.000001';

use Test2::Harness::UI::Util::HashBase qw/-config_file/;

use Plack::Builder;
use Test2::Harnes::UI::Controller::Feed;

sub schema {
    my $self = shift;
}

sub to_app {
    my $self = shift;

    return builder {
        mount "/feed" => Test2::Harnes::UI::Controller::Feed->new(ui => $self)->to_app;

        mount "/" => sub {
            my $env = shift;

            return ['200', ['Content-Type' => 'text/html'], ["<html>Hello World</html>"]];
        };
    };
}

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI - Work in progress

=head1 DESCRIPTION

Work in progress

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2018 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
