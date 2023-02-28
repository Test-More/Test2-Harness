package Test2::Harness::UI::Controller::ReRun;
use strict;
use warnings;

our $VERSION = '0.000135';

use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Rerun' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    $res->header('Cache-Control' => 'no-store');

    die error(404 => 'Missing route') unless $route;
    my $run_id       = $route->{run_id};
    my $project_name = $route->{project};
    my $username     = $route->{username};

    error(404 => 'No source') unless $run_id || ($project_name && $username);
    my $schema = $self->{+CONFIG}->schema;

    my $query = {};
    my $attrs = {order_by => {'-desc' => 'run_ord'}, rows => 1};

    my $run;
    my $ok = eval {
        $run = $schema->vague_run_search(
            query => $query,
            attrs => $attrs,

            username     => $username,
            project_name => $project_name,
            source       => $run_id,
        );
        1;
    };
    my $err = $@;
    die error(400 => "Invalid Request: $err") unless $ok;
    die error(404 => 'No Data')               unless $run;

    my $data = $run->rerun_data;

    $res->content_type('application/json');
    $res->raw_body($data);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Files

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
