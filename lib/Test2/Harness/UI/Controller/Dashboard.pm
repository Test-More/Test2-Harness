package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

our $VERSION = '0.000028';

use Data::GUID;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Dashboard';

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_js('dashboard.js');
    $res->add_css('dashboard.css');

    my $user = $req->user;

    my $tx      = Text::Xslate->new(path => [share_dir('templates')]);
    my $content = $tx->render(
        'dashboard.tx',
        {
            base_uri => $req->base->as_string,
            user     => $user,
        }
    );

    $res->raw_body($content);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Dashboard

=head1 DESCRIPTION

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
