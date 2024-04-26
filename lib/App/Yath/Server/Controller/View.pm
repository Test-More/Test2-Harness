package App::Yath::Server::Controller::View;
use strict;
use warnings;

our $VERSION = '2.000000';

use Data::GUID;
use Text::Xslate(qw/mark_raw/);
use App::Yath::Server::Util qw/share_dir find_job/;
use App::Yath::Server::Response qw/resp error/;
use App::Yath::Schema::UUID qw/uuid_inflate/;

use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'YathUI';

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_js('runtable.js');
    $res->add_js('jobtable.js');
    $res->add_js('eventtable.js');
    $res->add_js('view.js');

    my $schema = $self->{+CONFIG}->schema;

    my $id     = $route->{id};
    my $uuid   = uuid_inflate($id);
    my $run_id = $route->{run_id};
    my ($project, $user);

    if ($id) {
        my $p_rs = $schema->resultset('Project');
        $project //= eval { $p_rs->find({name => $id}) };
        $project //= eval { $p_rs->find({project_id => $uuid}) };

        if ($project) {
            $uuid = uuid_inflate($project->project_id);
            $self->{+TITLE} .= ">" . $project->name;
        }
        else {
            my $u_rs = $schema->resultset('User');
            $user //= eval { $u_rs->find({username => $id}) };
            $user //= eval { $u_rs->find({user_id => $uuid}) };

            if ($user) {
                $uuid = uuid_inflate($user->user_id);
                $self->{+TITLE} .= ">" . $user->username;
            }
            else {
                $run_id //= $uuid;
            }
        }
    }

    if($run_id) {
        $run_id = uuid_inflate($run_id) or die error(404 => 'Invalid Run');

        my $run = eval { $schema->resultset('Run')->find({run_id => $run_id}) } or die error(404 => 'Invalid Run');
        $self->{+TITLE} .= ">" . $run->project->name;
    }

    my $job_uuid = $route->{job};
    my $job_try  = $route->{try};

    if ($job_uuid) {
        $job_uuid = uuid_inflate($job_uuid) or die error(404 => 'Invalid Job');
        my $job = find_job($schema, $job_uuid, $job_try) or die error(404 => 'Invalid Job');
        $self->{+TITLE} .= ">" . ($job->shortest_file // 'HARNESS');
    }

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri   = $req->base->as_string;
    my $stream_uri = join '/' => $base_uri . 'stream', grep {length $_} ($uuid // $run_id), $job_uuid, $job_try;

    my $content = $tx->render(
        'view.tx',
        {
            base_uri   => $req->base->as_string,
            user       => $req->user,
            stream_uri => $stream_uri,
        }
    );

    $res->raw_body($content);
    return $res;
}

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::View

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
