package Test2::Harness::UI::Controller::Binary;
use strict;
use warnings;

our $VERSION = '0.000129';

use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Binary' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    die error(404 => 'Missing route') unless $route;
    my $binary_id = $route->{binary_id};

    error(404 => 'No id') unless $binary_id;

    my $schema = $self->{+CONFIG}->schema;
    my $binary = $schema->resultset('Binary')->find({binary_id => $binary_id});

    error(404 => 'No such binary file') unless $binary_id;

    my $filename = $binary->filename;

    $res->content_type('application/x-binary');

    if ($binary->is_image) {
        $res->header('Content-Disposition' => "inline; filename=" . $filename);
    }
    else {
        $res->header('Content-Disposition' => "attachment; filename=" . $filename);
    }

    $res->body($binary->data);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Binary

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

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
