package Test2::Harness::UI::Controller::Coverage;
use strict;
use warnings;

our $VERSION = '0.000028';

use Data::GUID;
use List::Util qw/max/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Coverage' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    die error(404 => 'Missing route') unless $route;
    my $project_name = $route->{project} or die error(404 => 'No project');

    my $schema  = $self->{+CONFIG}->schema;
    my $project = $schema->resultset('Project')->find({name => $project_name});

    my $data;
    if ($req->method eq 'POST') {
        my $files;
        eval { $files = decode_json($req->content); 1 } or warn $@;
        die error(400 => 'POST content must be a JSON array (list of filenames)') unless $files && ref($files) eq 'ARRAY';
        my $dbh = $self->{+CONFIG}->connect;

        my $placeholders = join ',' => map { '?' } @$files;
        my $sth = $dbh->prepare(<<"        EOT");
            SELECT DISTINCT(jobs.file) AS file FROM jobs
              JOIN coverage USING(job_key)
              JOIN runs     USING(run_id)
             WHERE runs.project_id = ?
               AND coverage.file IN ($placeholders)
        EOT

        $sth->execute($project->project_id, @$files) or die $sth->errstr;
        my $rows = $sth->fetchall_arrayref;

        $data = [map { $_->[0] } @$rows];
    }
    elsif ($req->method eq 'GET') {
        my $dbh = $self->{+CONFIG}->connect;

        my $sth = $dbh->prepare(<<"        EOT");
            SELECT DISTINCT
                   coverage.file AS source,
                   jobs.file     AS test
              FROM coverage
              JOIN jobs USING(job_key)
              JOIN runs USING(run_id)
             WHERE runs.project_id = ?
        EOT

        $data = {};
        $sth->execute($project->project_id) or die $sth->errstr;
        for my $row (@{$sth->fetchall_arrayref}) {
            push @{$data->{$row->[0]}} => $row->[1];
        }
    }
    else {
        die error(405);
    }

    my $ct ||= lc($req->headers->{'content-type'} || $req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html; charset=utf-8');
    $res->content_type($ct);

    if ($ct eq 'application/json') {
        $res->raw_body($data);
    }
    else {
        $res->raw_body("<pre>" . encode_pretty_json($data) . "</pre>");
    }

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Coverage

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
