package Test2::Harness::UI::Controller::View;
use strict;
use warnings;

our $VERSION = '0.000065';

use Data::GUID;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

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

    my $user = $req->user;

    my $schema = $self->{+CONFIG}->schema;

    my $run_id = $route->{run_id};
    if($run_id) {
        my $run = $schema->resultset('Run')->search({run_id => $run_id})->first or die error(404 => 'Invalid Run');
        $self->{+TITLE} .= ">" . $run->project->name;
    }

    my $job_key = $route->{job_key};
    if ($job_key) {
        my $job = $schema->resultset('Job')->search({job_key => $job_key})->first or die error(404 => 'Invalid Job');
        $self->{+TITLE} .= ">" . ($job->shortest_file // 'HARNESS');
    }

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);

    my $base_uri   = $req->base->as_string;
    my $stream_uri = join '/' => $base_uri . 'stream', grep {$_} $run_id, $job_key;

    my $content = $tx->render(
        'view.tx',
        {
            base_uri   => $req->base->as_string,
            user       => $user,
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

Test2::Harness::UI::Controller::View

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
