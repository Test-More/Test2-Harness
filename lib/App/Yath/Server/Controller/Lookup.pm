package App::Yath::Server::Controller::Lookup;
use strict;
use warnings;

our $VERSION = '2.000005';

use App::Yath::Server::Response qw/resp error/;
use App::Yath::Util qw/share_dir/;
use App::Yath::Schema::Util qw/find_job/;
use Test2::Harness::Util::JSON qw/encode_json/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Yath';

    my $req = $self->{+REQUEST};

    my $lookup = $route->{lookup} // $req->param('lookup') or die error(404 => 'Nothing to lookup') ;
    return $self->data($lookup) if $route->{data};

    my $res = resp(200);
    $res->add_css('view.css');
    $res->add_js('runtable.js');
    $res->add_js('jobtable.js');
    $res->add_js('eventtable.js');
    $res->add_js('lookup.js');

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri = $req->base->as_string;
    my $data_uri = join '/' => $base_uri . 'lookup', 'data', $lookup;

    my $content = $tx->render(
        'lookup.tx',
        {
            base_uri   => $req->base->as_string,
            user       => $req->user,
            data_uri   => $data_uri,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub data {
    my $self = shift;
    my ($lookup) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    my @sources = qw/run job event/;

    my @out;

    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl; charset=utf-8',

        done => sub {
            return 0 if @out;
            return 0 if @sources;
            return 1;
        },

        fetch => sub {
            return shift @out if @out;

            return unless @sources;
            my $source = shift @sources;
            my $meth = "lookup_$source";
            push @out => $self->$meth($lookup, {});

            return shift @out;
        },
    );

    return $res;
}

sub lookup_run {
    my $self = shift;
    my ($lookup, $state) = @_;

    return unless $lookup;

    return if $state->{run}->{$lookup}++;

    my $schema = $self->schema;

    my $rs = $schema->resultset('Run');
    my $run = $rs->find_by_id_or_uuid($lookup);

    return () unless $run;
    return (
        encode_json({type => 'run', data => $run }) . "\n",
    );
}

sub lookup_job {
    my $self = shift;
    my ($lookup, $state, $try_id) = @_;

    return unless $lookup;

    return if $state->{job}->{$lookup}++;

    my $schema = $self->schema;

    my $rs = $schema->resultset('Job');
    my $job = $rs->find_by_id_or_uuid($lookup);
    return () unless $job;

    return (
        $self->lookup_run($job->run_id, $state),
        encode_json({type => 'job', data => $job->glance_data(try_id => $try_id)}) . "\n",
    );
}

sub lookup_job_try {
    my $self = shift;
    my ($lookup, $state) = @_;

    return unless $lookup;

    return if $state->{job_try}->{$lookup}++;

    my $schema = $self->schema;

    my $rs = $schema->resultset('JobTry');
    my $try = $rs->find({job_try_id => $lookup});
    return () unless $try;

    return (
        $self->lookup_job($try->job_id, $state, try => $try->job_try_id),
    );
}

sub lookup_event {
    my $self = shift;
    my ($lookup, $state) = @_;

    return unless $lookup;

    return if $state->{event}->{$lookup}++;

    my $schema = $self->schema;

    my $rs = $schema->resultset('Event');
    my $event = $rs->find_by_id_or_uuid($lookup);

    return () unless $event;

    return (
        $self->lookup_job_try($event->job_try_id, $state),
        encode_json({type => 'event', data => $event->line_data }) . "\n"
    );
}

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Lookup - Controller for searching

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

