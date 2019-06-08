package Test2::Harness::UI::Controller::Jobs;
use strict;
use warnings;

our $VERSION = '0.000003';

use Data::GUID;
use List::Util qw/max/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Jobs' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);

    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{id} or die error(404 => 'No id');

    my $schema = $self->{+CONFIG}->schema;
    my $run = $schema->resultset('Run')->search({run_id => $it})->first or die error(404 => 'Invalid Run');

    my $offset = 0;
    $res->stream(
        env          => $req->env,
        content_type => 'application/x-jsonl',

        done  => sub { $run->complete },
        fetch => sub {
            my @jobs = map {encode_json($_) . "\n"} sort _sort_jobs $run->jobs(undef, {offset => $offset, order_by => {-asc => 'job_ord'}})->all;
            $offset += @jobs;
            return @jobs;
        },
    );

    return $res;
}

sub _sort_jobs($$) {
    my ($a, $b) = @_;

    return -1 unless $a->file;
    return 1  unless $b->file;

    my $delta = $b->fail <=> $a->fail;
    return $delta if $delta;

    my ($a_name) = $a->name =~ m/(\d+)$/;
    my ($b_name) = $b->name =~ m/(\d+)$/;
    $delta = int($a_name) <=> int($b_name);
    return $delta if $delta;

    return $a->file cmp $b->file || $a->job_ord <=> $b->job_ord;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Jobs

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
