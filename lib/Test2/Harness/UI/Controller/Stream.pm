package Test2::Harness::UI::Controller::Stream;
use strict;
use warnings;

our $VERSION = '0.000099';

use Data::GUID;
use List::Util qw/max/;
use Test2::Harness::UI::Util qw/find_job/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json/;
use JSON::PP();
use Carp qw/croak/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw{
    <run
    <job
};

use constant RUN_LIMIT => 100;

sub title { 'Stream' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    my @sets = (
        $self->stream_runs($req, $route),
        $self->stream_jobs($req, $route),
        $self->stream_events($req, $route),
    );

    my $cache = 1;
    for my $it ($self->{+RUN}, $self->{+JOB}) {
        next unless $it;
        next if $it->complete;
        $cache = 0;
        last;
    }

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        cache => $cache,

        done => sub {
            my @keep;
            while (my $set = shift @sets) {
                my ($check) = @$set;
                next if $check->(); # Next if done

                # Not done, keep it
                push @keep => $set;
            }

            @sets = @keep;

            return @sets ? 0 : 1;
        },

        fetch => sub { map { $_->[1]->() } @sets },
    );

    return $res;
}

sub stream_runs {
    my $self = shift;
    my ($req, $route) = @_;

    my $schema = $self->{+CONFIG}->schema;

    my $opts = {
        collapse       => 1,
        remove_columns => [qw/log_data run_fields.data parameters/],

        join       => [qw/user_join project run_fields/],
        '+columns' => {
            'prefetched_fields'       => \'1',
            'run_fields.run_field_id' => 'run_fields.run_field_id',
            'run_fields.name'         => 'run_fields.name',
            'run_fields.details'      => 'run_fields.details',
            'run_fields.raw'          => 'run_fields.raw',
            'run_fields.link'         => 'run_fields.link',
            'run_fields.data',        => \"run_fields.data IS NOT NULL",
            'user'                    => \'user_join.username',
            'project'                 => \'project.name',
        },
    };

    my %params = (
        type => 'run',

        req => $req,

        track_status  => 1,
        id_field      => 'run_id',
        ord_field     => 'run_ord',
        sort_field    => 'run_ord',
        search_base   => $schema->resultset('Run'),
        initial_limit => RUN_LIMIT,

        custom_opts => $opts,

        timeout => 60 * 30,    # 30 min.
    );

    my $id     = $route->{id};
    my $run_id = $route->{run_id};
    my ($project, $user);

    if ($id) {
        my $p_rs = $schema->resultset('Project');
        $project //= eval { $p_rs->search({project_id => $id})->first };
        $project //= eval { $p_rs->search({name => $id})->first };

        if ($project) {
            $params{search_base} = $params{search_base}->search_rs({project_id => $project->project_id});
        }
        else {
            my $u_rs = $schema->resultset('User');
            $user //= eval { $u_rs->search({user_id  => $id})->first };
            $user //= eval { $u_rs->search({username => $id})->first };

            if ($user) {
                $params{search_base} = $params{search_base}->search_rs({'me.user_id' => $user->user_id});
            }
            else {
                $run_id //= $id;
            }
        }
    }

    if($run_id) {
        return $self->stream_single(%params, id => $run_id);
    }

    return $self->stream_set(%params);
}

sub stream_jobs {
    my $self = shift;
    my ($req, $route) = @_;

    my $run = $self->{+RUN} // return;

    my $opts = {
        join => 'test_file',
        remove_columns => [qw/stdout stderr parameters/],
        '+select' => [
            'test_file.filename AS file',
        ],
        '+as' => [
            'file',
        ],
    };

    my %params = (
        type   => 'job',
        parent => $run,

        req => $req,

        track_status => 1,
        id_field     => 'job_key',
        ord_field    => 'job_ord',
        method       => 'glance_data',
        search_base  => scalar($run->jobs),
        custom_opts  => $opts,

        order_by => [{'-desc' => 'status'}, {'-desc' => [qw/job_try job_ord name/]}],
    );

    if (my $job_uuid = $route->{job}) {
        my $schema = $self->{+CONFIG}->schema;
        return $self->stream_single(%params, item => find_job($schema, $job_uuid, $route->{try}));
    }

    return $self->stream_set(%params);
}

sub stream_events {
    my $self = shift;
    my ($req, $route) = @_;

    my $job = $self->{+JOB} // return;

    # we only stream nested events when the job is still running
    my $query = $job->complete ? {nested => 0} : undef;

    my $opts = {
        remove_columns => ['orphan'],
        '+select' => [
            'facets IS NOT NULL AS has_facets',
            'orphan IS NOT NULL AS has_orphan',
        ],
        '+as' => [
            'has_facets',
            'has_orphan',
        ],
    };

    return $self->stream_set(
        type   => 'event',
        parent => $job,

        req => $req,

        track_status => 0,
        id_field     => 'event_id',
        ord_field    => 'insert_ord',
        sort_field   => 'event_ord',
        sort_dir     => '-asc',
        method       => 'line_data',
        custom_query => $query,
        custom_opts  => $opts,
        search_base  => scalar($job->events),
    );
}

sub stream_single {
    my $self = shift;
    my %params = @_;

    my $id_field    = $params{id_field};
    my $method      = $params{method};
    my $search_base = $params{search_base};
    my $type        = $params{type};
    my $id          = $params{id};
    my $custom_opts  = $params{custom_opts} // {};
    my $custom_query = $params{custom_query} // {};

    my $it;
    if (exists $params{item}) {
        $it = $params{item} or die error(404 => "Invalid Item");
    }
    else {
        $it = $search_base->search({%$custom_query, "me.$id_field" => $id}, $custom_opts)->first or die error(404 => "Invalid $type");
    }
    $self->{$type} = $it;

    my $sig;
    return [
        sub { $sig && $it->complete ? 1 : 0 },
        sub {
            my $update = JSON::PP::false;
            if ($sig) {
                $it->discard_changes;
                $update = JSON::PP::true;
            }

            my $new_sig   = $it->sig;
            my $unchanged = $sig && $sig eq $new_sig;
            $sig = $new_sig;

            return if $unchanged;

            my $data = $method ? $it->$method : $it->TO_JSON;
            return encode_json({type => $type, update => $update, data => $data}) . "\n";
        },
    ];
}

sub stream_set {
    my $self = shift;
    my (%params) = @_;

    my $custom_opts  = $params{custom_opts} // {};
    my $custom_query = $params{custom_query} // undef;
    my $id_field     = $params{id_field};
    my $limit        = $params{initial_limit};
    my $method       = $params{method};
    my $ord_field    = $params{ord_field};
    my $parent       = $params{parent};
    my $search_base  = $params{search_base};
    my $sort_field   = $params{sort_field};
    my $sort_dir     = $params{sort_dir} // '-desc';
    my $timeout      = $params{timeout};
    my $track        = $params{track_status};
    my $type         = $params{type};

    my $order_by = $params{order_by} // $sort_field ? {$sort_dir => $sort_field} : croak "Must specify either 'order_by' or 'sort_field'";

    my $items = $search_base->search($custom_query, {%$custom_opts, order_by => $order_by, $limit ? (rows => $limit) : ()});

    my $start = time;
    my $ord = 0;
    my $incomplete = {};

    return [
        sub {
            return 0 if $items;
            return 0 if $track && keys %$incomplete;

            return 1 if $parent && $parent->complete;

            my $running = time - $start;
            return 1 if $timeout && $running > $timeout; # Stop if they have been camping the page for 30 min.

            return 0;
        },
        sub {
            unless ($items) {
                my $query = {
                    ($custom_query ? %$custom_query : ()),
                    $ord_field => {'>' => $ord},
                };

                my @ids = $track ? keys %$incomplete : ();
                $query = [$query, {"me.$id_field" => {'IN' => \@ids}}] if @ids;

                $items = $search_base->search(
                    $query,
                    {%$custom_opts, order_by => $order_by}
                );
            }

            while (my $item = $items->next()) {
                $ord = max($ord, $item->$ord_field);

                my $update = JSON::PP::false;
                if ($track) {
                    my $id = $item->$id_field;
                    if (my $old = $incomplete->{$id}) {
                        $update = JSON::PP::true;
                        # Nothing has changed, no need to send it.
                        next if $old->sig eq $item->sig;
                    }

                    if ($item->complete) {
                        delete $incomplete->{$id};
                    }
                    else {
                        $incomplete->{$id} = $item;
                    }
                }

                my $data = $method ? $item->$method : $item->TO_JSON;
                return encode_json({type => $type, update => $update, data => $data}) . "\n";
            }

            $items = undef;
            return;
        },
    ];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Stream

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
