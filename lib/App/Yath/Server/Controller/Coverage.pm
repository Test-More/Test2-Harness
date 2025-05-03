package App::Yath::Server::Controller::Coverage;
use strict;
use warnings;

our $VERSION = '2.000005';

use List::Util qw/max/;
use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json decode_json/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase;

sub title { 'Coverage' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};
    my $res = resp(200);

    my $schema = $self->schema;

    die error(404 => 'Missing route') unless $route;
    my $source = $route->{source} or die error(404 => 'No source');
    my $username = $route->{user};

    my $delete = $route->{delete};

    if ($username && $username eq 'delete') {
        $delete = 1;
        $username = undef;
    }

    my $run;
    if (my $project = $schema->resultset('Project')->find({name => $source})) {
        $run = $project->last_covered_run(user => $username);
    }
    else {
        $run = $schema->resultset('Run')->find_by_id_or_uuid($source) or die error(405);
    }

    die error(404) unless $run;

    if ($delete) {
        $run->coverage->delete;
        $run->update({has_coverage => 0});
    }
    else {
        my $iter = $run->coverage_data(iterator => 1);

        my $done = 0;
        $res->stream(
            env          => $req->env,
            content_type => 'application/x-jsonl; charset=utf-8',
            cache        => 0,
            headers      => ["content-disposition" => 'attachment; filename="coverage.jsonl"'],

            done => sub { $done },

            fetch => sub {
                if (my $item = $iter->()) {
                    return encode_json($item) . "\n";
                }
                else {
                    $done = 1;
                    return;
                }
            },
        );
    }

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Coverage - Controller for fetching coverage data.

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

