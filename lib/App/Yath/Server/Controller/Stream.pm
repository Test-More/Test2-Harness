package App::Yath::Server::Controller::Stream;
use strict;
use warnings;

our $VERSION = '2.000005';

use List::Util qw/max/;
use Scalar::Util qw/blessed/;
use App::Yath::Schema::Util qw/find_job_and_try format_uuid_for_db/;
use Test2::Util::UUID qw/looks_like_uuid/;

use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json/;
use JSON::PP();
use Carp qw/croak/;

use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw{
    <run
    <job
    <try
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
        env   => $req->env,
        cache => $cache,

        content_type => 'application/x-jsonl; charset=utf-8',

        done => sub {
            my @keep;
            while (my $set = shift @sets) {
                my ($check) = @$set;
                next if $check->();    # Next if done

                # Not done, keep it
                push @keep => $set;
            }

            @sets = @keep;

            return @sets ? 0 : 1;
        },

        fetch => sub {
            map { $_->[1]->() } @sets;
        },
    );

    return $res;
}

sub stream_runs {
    my $self = shift;
    my ($req, $route) = @_;

    my $schema = $self->schema;

    my $opts = {remove_columns => [qw/parameters/]};
    my %params = (
        type => 'run',

        req => $req,

        track_status  => 1,
        id_field      => 'run_id',
        ord_field     => 'run_id',
        sort_field    => 'run_id',
        search_base   => $schema->resultset('Run'),
        initial_limit => RUN_LIMIT,

        custom_opts => $opts,

        timeout => 60 * 30,    # 30 min.
    );

    my $run_id     = $route->{run_id};
    my $user_id    = $route->{user_id};
    my $project_id = $route->{project_id};


    my ($project, $user, $run);

    if($run_id) {
        $params{id_field} = 'run_uuid' if looks_like_uuid($run_id);
        return $self->stream_single(%params, id => $run_id);
    }

    if ($project_id) {
        my $p_rs = $schema->resultset('Project');
        $project = eval { $p_rs->find({name => $project_id}) } // eval { $p_rs->find({project_id => $project_id}) } // die error(404 => 'Invalid Project');
        $params{search_base} = $params{search_base}->search_rs({'me.project_id' => $project->project_id});
    }
    elsif ($user_id) {
        my $u_rs = $schema->resultset('User');
        $user = eval { $u_rs->find({username => $user_id}) } // eval { $u_rs->find({user_id => $user_id}) } // die error(404 => 'Invalid User');
        $params{search_base} = $params{search_base}->search_rs({'me.user_id' => $user->user_id});
    }

    return $self->stream_set(%params);
}

sub stream_jobs {
    my $self = shift;
    my ($req, $route) = @_;

    my $run = $self->{+RUN} // return;

    my $opts = {};

    my %params = (
        type   => 'job',
        parent => $run,

        req => $req,

        track_status => 1,
        id_field     => 'job_id',
        ord_field    => 'job_id',
        method       => 'glance_data',
        search_base  => scalar($run->jobs),
        custom_opts  => $opts,

        order_by => [{'-desc' => 'status'}, {'-desc' => [qw/job_try job_id name/]}],
    );

    if (my $job_uuid = $route->{job}) {
        my $schema = $self->schema;
        my ($job, $try) = find_job_and_try($schema, $job_uuid, $route->{try});
        $self->{+JOB} = $job;
        $self->{+TRY} = $try;
        return $self->stream_single(%params, item => $job);
    }

    return $self->stream_set(%params);
}

sub stream_events {
    my $self = shift;
    my ($req, $route) = @_;

    my $job = $self->{+JOB} // return;
    my $try = $self->{+TRY} // return;

    # we only stream nested events when the job is still running
    my $query = $try->complete ? {nested => 0} : undef;

    return $self->stream_set(
        type   => 'event',
        parent => $try,

        req => $req,

        track_status => 0,
        id_field     => 'event_id',
        ord_field    => 'event_idx',
        sort_field   => 'event_idx',
        sort_dir     => '-asc',
        method       => 'line_data',
        custom_query => $query,
        search_base  => scalar($try->events),
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
        $id = format_uuid_for_db($id) if $id_field =~ m/_uuid$/;
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

            my ($data) = $method ? $it->$method : $it->TO_JSON;
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
    my (@buffer, $buffer_item);

    my $start = time;
    my $ord;
    my $incomplete = {};
    my $update;

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
            unless ($items || @buffer) {
                my $val;
                if (blessed($ord) && $ord->isa('DateTime')) {
                    my $schema = $self->schema;
                    my $dtf = $schema->storage->datetime_parser;
                    $val = $dtf->format_datetime($ord);
                }
                else {
                    $val = $ord;
                }

                my $query = {
                    ($custom_query ? %$custom_query : ()),
                    defined($val) ? ($ord_field => {'>' => $val}) : (),
                };

                my @ids = $track ? keys %$incomplete : ();
                @ids = map { format_uuid_for_db($_) } @ids if $id_field =~ m/_uuid$/;
                $query = [$query, {"me.$id_field" => { -in => \@ids }}] if @ids;

                $items = $search_base->search(
                    $query,
                    {%$custom_opts, order_by => $order_by}
                );
            }

            while (1) {
                my ($item);

                if (@buffer) {
                    $item = $buffer_item;
                }
                else {
                    $item = $items->next() or last;

                    $ord = max($ord || 0, $item->$ord_field);

                    $update = JSON::PP::false;

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
                }

                unless (@buffer) {
                    @buffer = $method ? $item->$method : $item->TO_JSON;
                    $buffer_item = $item;
                }

                return encode_json({type => $type, update => $update, data => shift(@buffer)}) . "\n";
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

App::Yath::Server::Controller::Stream - Controller for streaming data that is still being generated.

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

