package Test2::Harness::UI::Controller::Jobs;
use strict;
use warnings;

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
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
    my $query = [{run_id => $it}];

    my $run = $user->runs($query)->first or die error(404 => 'Invalid run');

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
