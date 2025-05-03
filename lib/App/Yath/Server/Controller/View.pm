package App::Yath::Server::Controller::View;
use strict;
use warnings;

our $VERSION = '2.000005';

use Text::Xslate(qw/mark_raw/);
use App::Yath::Util qw/share_dir/;
use App::Yath::Schema::Util qw/find_job_and_try/;
use App::Yath::Server::Response qw/resp error/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Yath';

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_js('runtable.js');
    $res->add_js('jobtable.js');
    $res->add_js('eventtable.js');
    $res->add_js('view.js');

    my $schema = $self->schema;

    my $run_id     = $route->{run_id};
    my $user_id    = $route->{user_id};
    my $project_id = $route->{project_id};
    my ($project, $user, $run);

    my @url;
    if ($project_id) {
        my $p_rs = $schema->resultset('Project');
        $project = eval { $p_rs->find({name => $project_id}) } // eval { $p_rs->find({project_id => $project_id}) } // die error(404 => 'Invalid Project');
        $self->{+TITLE} .= ">" . $project->name;
        @url = ('project', $project_id);
    }
    elsif ($user_id) {
        my $u_rs = $schema->resultset('User');
        $user = eval { $u_rs->find({username => $user_id}) } // eval { $u_rs->find({user_id => $user_id}) } // die error(404 => 'Invalid User');
        $self->{+TITLE} .= ">" . $user->username;
        @url = ('user', $user_id);
    }
    elsif($run_id) {
        push @url => $run_id;

        $run = eval { $schema->resultset('Run')->find_by_id_or_uuid($run_id) } or die error(404 => 'Invalid Run');
        $self->{+TITLE} .= ">" . $run->project->name;

        my $job_try = $route->{try};

        if (my $job_uuid = $route->{job}) {
            my ($job, $try) = find_job_and_try($schema, $job_uuid, $job_try) or die error(404 => 'Invalid Job');
            $self->{+TITLE} .= ">" . ($job->shortest_file // 'HARNESS');
            push @url => $job_uuid;
        }

        push @url => $job_try if $job_try;
    }

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri   = $req->base->as_string;
    my $stream_uri = join '/' => $base_uri . 'stream', @url;

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

App::Yath::Server::Controller::View - Used for veiwing items

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

