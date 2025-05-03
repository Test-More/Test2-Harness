package App::Yath::Server::Controller::Job;
use strict;
use warnings;

our $VERSION = '2.000005';

use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use App::Yath::Util qw/share_dir/;
use App::Yath::Schema::Util qw/find_job_and_try/;
use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);

    my $schema = $self->schema;
    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{job} or die error(404 => 'No job uuid');
    my $ord = $route->{try};

    my ($job, $try) = find_job_and_try($schema, $it, $ord);
    die error(404 => 'Invalid Job') unless $job && $try;

    $self->{+TITLE} = 'Job: ' . ($job->file || $job->name) . ' - ' . $job->job_id . '+' . $try->job_try_ord;

    $res->content_type('application/json');
    $res->raw_body({job => $job, try => $try});
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::Job - Controller for viewing a job

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

