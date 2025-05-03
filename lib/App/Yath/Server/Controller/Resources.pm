package App::Yath::Server::Controller::Resources;
use strict;
use warnings;

our $VERSION = '2.000005';

use DateTime;
use Scalar::Util qw/blessed/;
use App::Yath::Server::Response qw/resp error/;
use App::Yath::Util qw/share_dir/;
use App::Yath::Schema::Util qw/find_job/;
use App::Yath::Schema::DateTimeFormat qw/DTF/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Util::Times qw/render_duration/;

use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Yath Run Resources';

    my $req = $self->{+REQUEST};

    my $schema = $self->schema;

    # Test run
    my $run_id  = $route->{run_id} or die error(404 => 'No run ID or UUID provided');
    my $run = $schema->resultset('Run')->find_by_id_or_uuid($run_id) or die error(404 => "Invalid Run");

    die error(400 => "This run does not have any resource data.") unless $run->has_resources;

    my $res_ord = $route->{ord};

    if ($route->{data}) {
        return $self->res_max($run) if $route->{max};
        return $self->res_min($run) if $route->{min};
        return $self->res_ord($run, $res_ord) if $res_ord;
        return $self->res_stream($req, $run);
    }

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_css('resources.css');
    $res->add_js('resources.js');
    $res->add_js('runtable.js');

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri = $req->base->as_string;
    my $res_uri  = join '/' => $base_uri . 'resources', $run_id;
    my $data_uri = join '/' => $base_uri . 'resources', $run_id, 'data';
    $res_uri  =~ s{/$}{}g;
    $data_uri =~ s{/$}{}g;

    my $content = $tx->render(
        'resources.tx',
        {
            user     => $req->user,
            base_uri => $base_uri,
            res_uri  => $res_uri,
            data_uri => $data_uri,
            selected => $res_ord,
            tailing  => $res_ord ? 0 : 1,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub get_min_ord {
    my $self = shift;
    my ($run) = @_;

    my $schema = $self->schema;
    my $dbh = $schema->storage->dbh;

    my $sth = $dbh->prepare("SELECT MIN(resource_ord) FROM resources WHERE run_id = ?");
    $sth->execute($run->run_id);
    my $row = $sth->fetchrow_arrayref() or return 0;
    return $row->[0] // 0;
}

sub get_max_ord {
    my $self = shift;
    my ($run) = @_;

    my $schema = $self->schema;
    my $dbh = $schema->storage->dbh;

    my $sth = $dbh->prepare("SELECT MAX(resource_ord) FROM resources WHERE run_id = ?");
    $sth->execute($run->run_id);
    my $row = $sth->fetchrow_arrayref() or return 0;
    return $row->[0] // 0;
}

sub res_max {
    my $self = shift;
    my ($run) = @_;

    my $res = resp(200);
    $res->content_type('text/plain');
    $res->body($self->get_max_ord($run));
    return $res;
}

sub res_min {
    my $self = shift;
    my ($run) = @_;

    my $res = resp(200);
    $res->content_type('text/plain');
    $res->body($self->get_min_ord($run));
    return $res;
}

sub get_up_to {
    my $self = shift;
    my ($run, $ord) = @_;

    my $schema = $self->schema;
    my $dbh = $schema->storage->dbh;

    my $sth = $dbh->prepare(<<'    EOT');
        SELECT name, stamp, resource_ord, data
          FROM resources
          JOIN resource_types USING(resource_type_id)
         WHERE resource_id IN (
            SELECT MAX(resource_id)
              FROM resources
             WHERE run_id = ?
               AND resource_ord <= ?
             GROUP BY resource_type_id
         );
    EOT

    $sth->execute($run->run_id, $ord);

    return {ord => $ord, resources => [map { $_->{data} = decode_json($_->{data}); $_ } @{$sth->fetchall_arrayref({})}]};
}

sub res_ord {
    my $self = shift;
    my ($run, $ord) = @_;

    my $data = $self->get_up_to($run, $ord);

    my $res = resp(200);
    $res->content_type('application/json');
    $res->raw_body($data);
    return $res;
}

sub res_stream {
    my $self = shift;
    my ($req, $run) = @_;

    my $current;
    my $complete = 0;

    my $min = $self->get_min_ord($run);

    my $run_uuid = $run->run_uuid;
    my $run_sent = 0;

    my $res = resp(200);
    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',
        done => sub { $complete },

        fetch => sub {
            return () if $complete;

            unless ($run_sent) {
                $run_sent = 1;
                return encode_json({run_uuid => $run_uuid}) . "\n";
            }

            $run->discard_changes;
            my $run_complete = $run->complete;
            my $max = $self->get_max_ord($run);
            if (defined $current && $max <= $current) {
                $complete = 1 if $run_complete;
                return unless $complete;
                return encode_json({min => $min, max => $max, complete => $complete, data => undef}) . "\n";
            }

            $min //= $self->get_min_ord($run);
            my $data = $self->get_up_to($run, $max);
            $current = $max;

            for my $res (@{$data->{resources} // []}) {
                for my $item (@{$res->{data} // []}) {
                    for my $table (@{$item->{tables} // []}) {
                        my $format = $table->{format} or next;
                        my $rows   = $table->{rows} or next;
                        for (my $idx = 0; $idx < @$format; $idx++) {
                            my $fmt = $format->[$idx] or next;

                            if ($fmt eq 'duration') {
                                for my $row (@$rows) {
                                    $row->[$idx] = render_duration($row->[$idx]);
                                }
                            }
                        }
                    }
                }
            }

            return encode_json({min => $min, max => $max, complete => $complete, data => $data}) . "\n";
        },
    );

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Resources - controller for fetching resource data.

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

