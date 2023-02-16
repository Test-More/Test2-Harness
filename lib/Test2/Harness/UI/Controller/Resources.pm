package Test2::Harness::UI::Controller::Resources;
use strict;
use warnings;

our $VERSION = '0.000133';

use DateTime;
use Data::GUID;
use Scalar::Util qw/blessed/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::UI::Util qw/share_dir find_job/;
use Test2::Harness::UI::Util::DateTimeFormat qw/DTF/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Util::Times qw/render_duration/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'YathUI';

    my $req = $self->{+REQUEST};

    # Test run, Host, or resource instance
    my $id = $route->{id} or die error(404 => 'No id provided');

    # Specific instant
    my $batch = $route->{batch};

    if ($route->{data}) {
        return $self->data_stamps($req, $id) unless $batch;
        return $self->data($req, $id, $batch);
    }

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_css('resources.css');
    $res->add_js('resources.js');
    $res->add_js('runtable.js');

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri  = $req->base->as_string;
    my $stamp_uri = join '/' => $base_uri . 'resources', 'data', $id;
    my $res_uri   = join '/' => $base_uri . 'resources', $id;
    $stamp_uri =~ s{/$}{}g;
    $res_uri =~ s{/$}{}g;

    my $content = $tx->render(
        'resources.tx',
        {
            user      => $req->user,
            base_uri  => $req->base->as_string,
            stamp_uri => $stamp_uri,
            res_uri   => $res_uri,
            tailing   => $batch ? 0      : 1,
            selected  => $batch ? $batch : undef,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub get_thing {
    my $self = shift;
    my ($id) = @_;

    my $schema = $self->{+CONFIG}->schema;

    my ($thing, $stamp_start, $done_check);
    my $search_args = {};
    my $stamp_args  = {start => \$stamp_start};

    my $host_rs = $schema->resultset('Host');
    my $res_rs  = $schema->resultset('Resource');
    my $run_rs  = $schema->resultset('Run');

    if (!$id || lc($id) eq 'global') {
        $thing = undef;
        $search_args->{global} = 1;
    }
    else {
        if ($thing = eval { $run_rs->search({run_id => $id})->first }) {
            $search_args->{run_id} = $id;
            $done_check = sub {
                return 1 if $thing->complete;
                return 0;
            };
        }
        elsif ($thing = eval { $host_rs->search({host_id => $id})->first } || eval { $host_rs->search({hostname => $id})->first }) {
            $search_args->{host_id} = $id;
        }
        else {
            die error(404 => 'Invalid Job ID or Host ID');
        }
    }

    return ($thing, $search_args, $stamp_args, $done_check);
}

sub get_stamps {
    my $self = shift;
    my %params = @_;

    my $search_args = $params{search_args} || {};
    my $start = $params{start};

    my $schema = $self->{+CONFIG}->schema;
    my $dbh = $schema->storage->dbh;

    my $fields = "";
    my @vals;
    if ($search_args->{run_id}) {
        $fields = "run_id = ?";
        push @vals => $search_args->{run_id};
    }
    elsif ($search_args->{host_id}) {
        $fields = "host_id = ?";
        push @vals => $search_args->{host_id};
    }

    if ($$start) {
        $fields .= " AND stamp > ?";
        push @vals => $$start;
    }

    my $sth = $dbh->prepare("SELECT resource_batch_id, stamp FROM resource_batch WHERE " . $fields . " ORDER BY stamp ASC");
    $sth->execute(@vals) or die $sth->errstr;
    my $rows = $sth->fetchall_arrayref;

    return unless @$rows;

    $$start = $rows->[-1]->[1];

    return $rows;
}

sub data_stamps {
    my $self = shift;
    my ($req, $id) = @_;

    my $res = resp(200);
    my ($thing, $search_args, $stamp_args, $done_check) = $self->get_thing($id);

    my ($complete, @out);

    if (my $run_id = $search_args->{run_id}) {
        push @out => { run_id => $run_id };
    }
    if (my $host_id = $search_args->{host_id}) {
        push @out => { host_id => $host_id };
    }

    my $start   = time;
    my $advance = sub {
        return 0 if @out;
        return 1 if $complete;
        return 1 if (time - $start) > 600;

        if ($thing) {
            if (my $stamps = $self->get_stamps(%$stamp_args, search_args => $search_args)) {
                push @out => {stamps => $stamps};
            }

            # Finish if run is done
            if ($done_check && $done_check->()) {
                push @out => {complete => 1};
            }

            return 0;
        }

        push @out => {complete => 1};
        return 1;
    };

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        done         => $advance,

        fetch => sub {
            return () if $complete;

            $advance->() unless @out;

            my $item = shift @out or return ();
            $complete = 1 if $item->{complete};

            return encode_json($item) . "\n";
        },
    );

    return $res;
}

sub data {
    my $self = shift;
    my ($req, $id, $batch) = @_;

    my $res = resp(200);
    my ($thing, $search_args, $stamp_args, $done_check) = $self->get_thing($id);

    $res->content_type('application/json');
    $res->raw_body({
        resources => $self->render_stamp_resources(search_args => $search_args, batch => $batch),
    });

    return $res;
}

sub render_stamp_resources {
    my $self = shift;
    my %params = @_;

    my $search_args = $params{search_args};
    my $batch_id    = $params{batch};

    my $schema = $self->{+CONFIG}->schema;
    my $res_rs = $schema->resultset('Resource');

    my @res_list;
    my $resources = $res_rs->search({resource_batch_id => $batch_id}, {order_by => {'-asc' => 'batch_ord'}});
    while (my $res = $resources->next) {
        push @res_list => $self->render_resource($res);
    }

    return \@res_list;
}

sub render_resource {
    my $self = shift;
    my ($r) = @_;

    my $data = $r->data;

    for my $group (@{$data || []}) {
        for my $table (@{$group->{tables} || []}) {
            for my $row (@{$table->{rows} || []}) {
                my @formats = @{$table->{format} || []};

                for my $item (@{$row || []}) {
                    my $format = shift @formats or next;

                    unless ($format eq 'duration') {
                        $item = "$item (unsupported format '$format')";
                        next;
                    }

                    $item = render_duration($item);
                }
            }
        }
    }

    return {resource => $r->module, groups => $r->data};
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Resources

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
