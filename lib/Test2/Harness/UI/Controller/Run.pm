package Test2::Harness::UI::Controller::Run;
use strict;
use warnings;

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('run.css');

    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $it = $route->{name_or_id} or die error(404 => 'No name or id');
    my $query = [{name => $it}];
    push @$query => {run_id => $it} if eval { Data::GUID->from_string($it) };

    use Data::Dumper;
    print Dumper($query);

    my $run = $user->runs($query)->first or die error(404 => 'Invalid run');

    $self->{+TITLE} = 'Run: ' . $run->name;

    my $jobs = [ sort _sort_jobs $run->jobs->all];

    my $len = 0;
    @$jobs = map {
        my $class = $_->job_ord eq '0' ? 'harness_log' : ($_->fail ? 'fail' : 'pass');
        $len = max($len, length($_->name));
        {
            job   => $_,
            class => $class,
            name  => $_->name,
            file  => $_->short_file,
            id    => $_->job_id,
        }
    } @$jobs;

    my $template = share_dir('templates/run.tx');
    my $tx       = Text::Xslate->new();
    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            run      => $run,
            jobs     => $jobs,
            name_len => $len,
        }
    );

    $res->body($content);
    return $res;
}

sub _sort_jobs($$) {
    my ($a, $b) = @_;

    return -1 if $a->name eq '0';
    return 1  if $b->name eq '0';

    my $delta = $b->fail <=> $a->fail;
    return $delta if $delta;

    my ($a_name) = $a->name =~ m/(\d+)$/;
    my ($b_name) = $b->name =~ m/(\d+)$/;
    $delta = int($a_name) <=> int($b_name);
    return $delta if $delta;

    return $a->file cmp $b->file || $a->job_ord <=> $b->job_ord;
}

1;
