package Test2::Harness::UI::Controller::Run;
use strict;
use warnings;

our $VERSION = '0.000028';

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_js('dashboard.js');
    $res->add_js('run.js');

    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;

    my $run;

    if ($self->{+CONFIG}->single_run) {
        $run = $user->runs->first or die error(404 => 'Invalid run');
    }
    else {
        my $it = $route->{id} or die error(404 => 'No id');
        my $schema = $self->{+CONFIG}->schema;
        $run = $schema->resultset('Run')->search({run_id => $it})->first or die error(404 => 'Invalid Run');
    }

    $self->{+TITLE} = 'Run: ' . $run->project . ' - ' . $run->run_id;

    my $ct = lc($req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html');

    if ($route->{action} && $route->{action} eq 'pin_toggle') {
        $run->update({pinned => $run->pinned ? 0 : 1});
    }

    if ($ct eq 'application/json') {
        $res->content_type($ct);
        $res->raw_body($run);
        return $res;
    }

    my $tx      = Text::Xslate->new(path => [share_dir('templates')]);
    my $content = $tx->render(
        'run.tx',
        {
            base_uri => $req->base->as_string,
            user     => $user,
            run      => encode_json($run),
            run_id   => $run->run_id,
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

Test2::Harness::UI::Controller::Run

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
