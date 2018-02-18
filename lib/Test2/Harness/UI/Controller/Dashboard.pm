package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

use Data::GUID;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;


sub handle {
    my $self = shift;
    my ($route) = @_;

    $self->{+TITLE} = 'Dashboard';

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('dashboard.css');

    my $user = $req->user;

    my @dashboards;
    if ($route && $route->{name_or_id}) {
        my $query = [{name => $route->{name_or_id}}];

        push @$query => {dashboard_id => $route->{name_or_id}}
            if eval { Data::GUID->from_string($route->{name_or_id}) };

        my $db = $user->dashboards($query)->first or die error(404);
        $self->{+TITLE} = 'Dashboard: ' . $db->name;
        @dashboards = ( $self->build_dashboard($db) );
    }
    else {
        @dashboards = map { $self->build_dashboard($_) } $user->dashboards(undef, {order_by => {-asc => 'weight'}})->all;
    }

    my $template = share_dir('templates/dashboards.tx');
    my $tx       = Text::Xslate->new();
    my $content = $tx->render(
        $template,
        {
            base_uri => $req->base->as_string,
            user     => $user,
            dashboards => \@dashboards,
        }
    );

    $res->raw_body($content);
    return $res;
}

my %COLUMNS = (
    uploaded_by => {
        label => mark_raw('Uploaded&nbsp;By'), fetch => sub { $_[0]->user->username }
    },
    date => {label => 'Timestamp', fetch => sub { mark_raw($_[0]->added->datetime('&nbsp;&nbsp;')) }},
);

sub build_dashboard {
    my $self = shift;
    my ($dash) = @_;

    my $req    = $self->{+REQUEST};
    my $user   = $req->user;
    my $schema = $self->schema;

    my %attrs = (order_by => {-desc => 'added'});
    my $base_q = {};
    $base_q->{project} = $dash->show_project if defined $dash->show_project;
    $base_q->{version} = $dash->show_version if defined $dash->show_version;
    $base_q->{status} = ['complete'];

    unless ($dash->show_passes && $dash->show_failures && $dash->show_pending) {
        push @{$base_q->{failed}} => 0 if $dash->show_passes;
        push @{$base_q->{failed}} => {'>', 0} if $dash->show_failures;
    }

    if ($dash->show_pending) {
        push @{$base_q->{status}} => ('pending', 'running');
        push @{$base_q->{failed}} => undef if $base_q->{failed};
    }

    if ($dash->show_signoff_only) {
        push @{$attrs{join}} => 'signoff';
        $base_q->{'signoff.run_id'}    = {'is not', undef};
        $base_q->{'signoff.completed'} = {'is',     undef};
    }

    $base_q->{status} = 'failed' if $dash->show_errors_only;

    my @q;
    if ($dash->show_shared) {
        push @{$attrs{join}} => 'run_shares';
        push @q => {%$base_q, 'run_shares.user_id' => $user->user_id};
    }

    if ($dash->show_protected || $dash->show_public) {
        my $nq = {%$base_q, permissions => []};
        push @{$nq->{permissions}} => 'protected' if $dash->show_protected;
        push @{$nq->{permissions}} => 'public'    if $dash->show_public;
        push @q => $nq;
    }

    push @q => {%$base_q, 'me.user_id' => $user->user_id}
        if $dash->show_mine;

    my @runs = @q ? $schema->resultset('Run')->search(\@q, \%attrs) : ();

    my $template = share_dir('templates/dashboard.tx');
    my $tx       = Text::Xslate->new();

    my @cols = map { $COLUMNS{$_} || {label => ucfirst($_), fetch => $_ } } @{$dash->show_columns};
    my $header = [ map { $_->{label} } @cols ];

    my $rows = [];
    my $bad  = [];
    for my $run (@runs) {
        my $row = [];
        for my $col (@cols) {
            my $fetch = $col->{fetch};
            push @$row => $run->$fetch;
        }
        push @$rows => {vals => $row, class => $self->get_run_class($run), run_id => $run->run_id};
    }

    return mark_raw(
        $tx->render(
            $template,
            {
                base_uri => $req->base->as_string,
                user     => $user,
                dash     => $dash,
                header   => $header,
                rows     => $rows,
            }
        ),
    );
}

sub get_run_class {
    my $self = shift;
    my ($run) = @_;

    my $status = $run->status;

    return 'pending' if $status eq 'pending';
    return 'running' if $status eq 'running';
    return 'broken'  if $status eq 'failed';

    return 'failed' if $run->failed;
    return 'passed' if $run->passed;
    return 'unknown';
}

1;
