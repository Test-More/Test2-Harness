package Test2::Harness::UI::Controller::Job;
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
    $res->add_css('job.css');
    $res->add_js('run.js');
    $res->add_js('job.js');

    my $schema = $self->{+CONFIG}->schema;
    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No id');

    my $job = $schema->resultset('Job')->search({job_key => $it})->first or die error(404 => 'Invalid Job');

    $self->{+TITLE} = 'Job: ' . ($job->file || $job->name) . ' - ' . $job->job_id . '+' . $job->job_try;

    my $ct = lc($req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html; charset=utf-8');

    if ($ct eq 'application/json') {
        $res->content_type($ct);
        $res->raw_body($job);
        return $res;
    }

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);
    my $content = $tx->render(
        'job.tx',
        {
            base_uri => $req->base->as_string,
            user     => $user,
            job      => encode_json($job),
            job_key   => $job->job_key,
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

Test2::Harness::UI::Controller::Job

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
