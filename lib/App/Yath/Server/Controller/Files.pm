package App::Yath::Server::Controller::Files;
use strict;
use warnings;

our $VERSION = '2.000005';

use List::Util qw/max/;
use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json decode_json/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase;

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
    my $schema = $self->schema;

    my $query = {status => 'complete'};
    my $attrs = {order_by => {'-desc' => 'run_id'}, rows => 1};

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

    my $search = {is_harness_out => 0};
    if ($failed) {
        $search->{fail} = 1;
        $search->{retry} = 0;
    }

    my $files = $run->jobs->search(
        $search,
        {
            join => ['jobs_tries', 'test_file'],
            order_by => 'test_file.filename',
            group_by => ['me.job_id', 'test_file.filename'],
            '+select' => [{max => 'jobs_tries.job_try_id'}, {max => 'jobs_tries.job_try_ord'}, {bool_and => 'jobs_tries.fail'}],
            '+as' => ['job_try_id', 'job_try_ord', 'fail'],
        },
    );

    unless($json) {
        $res->content_type('text/plain');
        my $body = join "\n" => map { $_->file } $files->all;
        $res->body("$body\n");
        return $res;
    }

    my $run_uuid = $run->run_uuid;
    my $run_uri = $req->base . "view/$run_uuid";

    my $field_exclusions = {
        -and => [
            {name => {'-not_in'   => [qw/coverage files_covered/]}},
            {name => {'-not_like' => 'time_%'}},
            {name => {'-not_like' => 'mem_%'}},
        ]
    };

    my $data = {
        last_run_stamp => $run->added->epoch,
        run_uuid         => $run_uuid,
        run_uri        => $req->base . "view/" . $run->run_uuid,
        fields         => [$run->run_fields->search($field_exclusions)->all],
        failures       => [],
        passes         => [],
    };

    my $failures = $data->{failures};
    my $passes   = $data->{passes};

    while (my $file = $files->next) {
        my $job_uuid = $file->get_column('job_uuid');
        my $try_id   = $file->get_column('job_try_id');
        my $try_ord  = $file->get_column('job_try_ord');
        my $fail     = $file->get_column('fail');

        my $row = {
            file     => $file->file,
            fields   => [$schema->resultset('JobTryField')->search({job_try_id => $try_id, %$field_exclusions})->all],
            job_uuid => $job_uuid,
            job_try  => $try_id,
            uri      => "$run_uri/$job_uuid/$try_ord",
        };

        if ($fail) {
            my $subtests = {};

            my $event_rs = $schema->resultset('JobTry')->find({job_try_id => $try_id})->events({nested => 0, is_subtest => 1});
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

App::Yath::Server::Controller::Files - Controller for interacting with files

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

