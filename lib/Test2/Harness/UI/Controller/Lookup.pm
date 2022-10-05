package Test2::Harness::UI::Controller::Lookup;
use strict;
use warnings;

our $VERSION = '0.000128';

use Data::GUID;
use Scalar::Util qw/blessed/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::UI::Util qw/share_dir find_job/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'YathUI';

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

    my @sources = qw/run jobs event/;

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
    $lookup = $lookup->run_id if blessed($lookup);

    return if $state->{run}->{$lookup}++;

    my $schema = $self->{+CONFIG}->schema;

    my $rs = $schema->resultset('Run');
    my $run = eval { $rs->search({run_id => $lookup})->first };

    return () unless $run;
    return (
        encode_json({type => 'run', data => $run }) . "\n",
    );
}

sub lookup_jobs {
    my $self = shift;
    my ($lookup, $state) = @_;

    return unless $lookup;
    $lookup = $lookup->job_key if blessed($lookup);

    return if $state->{job}->{$lookup}++;

    my $schema = $self->{+CONFIG}->schema;

    my $rs = $schema->resultset('Job');

    my @out;

    for my $key (qw/job_id job_key/) {
        my $jobs = eval { $rs->search({$key => $lookup}) };

        while (my $job = eval { $jobs->next }) {
            push @out => $self->lookup_run($job->run_id, $state);
            push @out => encode_json({type => 'job', data => $job->glance_data }) . "\n";
        }
    }

    return @out;
}

sub lookup_event {
    my $self = shift;
    my ($lookup, $state) = @_;

    return unless $lookup;
    $lookup = $lookup->event_id if blessed($lookup);

    return if $state->{event}->{$lookup}++;

    my $schema = $self->{+CONFIG}->schema;

    my $rs = $schema->resultset('Event');
    my $event = eval { $rs->search({event_id => $lookup})->first };

    return () unless $event;

    return (
        $self->lookup_jobs($event->job_key, $state),
        encode_json({type => 'event', data => $event->line_data }) . "\n"
    );
}


__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Lookup

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
