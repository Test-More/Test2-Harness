package Test2::Harness::UI::Controller::Files;
use strict;
use warnings;

our $VERSION = '0.000119';

use Data::GUID;
use List::Util qw/max/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Files' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);
    $res->header('Cache-Control' => 'no-store');

    die error(404 => 'Missing route') unless $route;
    my $idx          = $route->{idx} //= 0;
    my $json         = $route->{json};
    my $project_name = $route->{project};
    my $source       = $route->{source};
    my $username     = $route->{username};
    my $failed       = $route->{failed};

    error(404 => 'No source') unless $source || $project_name;
    my $schema = $self->{+CONFIG}->schema;

    my $query = {status => 'complete'};
    my $attrs = {order_by => {'-desc' => 'run_ord'}, rows => 1};

    $attrs->{offset} = $idx if $idx;

    my $run;
    my $ok = eval {
        $run = $schema->vague_run_search(
            username     => $username,
            project_name => $project_name,
            source       => $source,
            idx          => $idx,
        );
        1;
    };
    my $err = $@;
    die error(400 => "Invalid Request: $err") unless $ok;
    die error(404 => 'No Data')               unless $run;

    my $search = {retry => 0};
    $search->{fail} = 1 if $failed;

    my $files = $run->jobs->search(
        $search,
        {join => 'test_file', order_by => 'test_file.filename'},
    );

    unless($json) {
        $res->content_type('text/plain');
        my $body = join "\n" => map { $_->file } $files->all;
        $res->body("$body\n");
        return $res;
    }

    my $run_id = $run->run_id;
    my $run_uri = $req->base . "view/$run_id";

    my $field_exclusions = {
        -and => [
            {name => {'-not_in'   => [qw/coverage files_covered/]}},
            {name => {'-not_like' => 'time_%'}},
            {name => {'-not_like' => 'mem_%'}},
        ]
    };

    my $data = {
        last_run_stamp => $run->added->epoch,
        run_id         => $run_id,
        run_uri        => $req->base . "view/" . $run->run_id,
        fields         => [$run->run_fields->search($field_exclusions)->all],
        failures       => [],
        passes         => [],
    };

    my $failures = $data->{failures};
    my $passes   = $data->{passes};

    while (my $file = $files->next) {
        my $job_key = $file->job_key;
        my $job_id  = $file->job_id;

        my $row = {
            file     => $file->file,
            fields   => [$file->job_fields->search($field_exclusions)->all],
            job_id   => $job_id,
            job_key  => $job_key,
            uri      => "$run_uri/$job_key",
        };

        if ($file->fail) {
            my $subtests = {};

            my $event_rs = $file->events({nested => 0, is_subtest => 1});
            while (my $event = $event_rs->next) {
                my $f = $event->facets;
                next unless $f->{assert};
                next if $f->{assert}->{pass};

                if ($f->{parent}) {
                    my $name = $f->{parent}->{details} || $f->{assert}->{details} || $f->{about}->{details} || 'unnamed subtest';
                    $subtests->{$name}++;
                }
                else {
                    $subtests->{'~'}++;
                }
            }

            $row->{subtests} = [sort keys %$subtests];

            push @$failures => $row;
        }
        else {
            push @$passes => $row;
        }
    }

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
