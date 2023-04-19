use Test2::V0;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use File::Spec;
use Atomic::Pipe;
use Child qw/child/;

use Test2::Harness::State;
use Test2::Harness::Settings;
use Test2::Harness::Util::File::JSONL;

use App::Yath::Util qw/find_yath/;
use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::Util::JSON qw/encode_json/;

my $yath = find_yath();
my $tmp = tempdir(CLEANUP => 1);

my $cnt = 0;
sub produce_output(&) {
    my $callback = shift;

    $cnt++;
    my $wdir = "$tmp/$cnt";
    mkdir($wdir) or die "$!";
    my $state_file = "$wdir/state$cnt";
    my $fifo_file  = "$wdir/fifo$cnt";
    my $out_file   = "$wdir/output$cnt";

    my $state = Test2::Harness::State->new(state_file => $state_file, workdir => $wdir, settings => Test2::Harness::Settings->new());
    $state->transaction('w' => sub { 1 } );

    my $parent = $$;
    my $agg = child {
        exec($^X, '-Ilib', $yath, '-D', 'aggregator', 'test_aggregator', $state_file, $fifo_file, $out_file, $parent);
        die "Failed to exec";
    };

    my $wait = 1;
    while ($wait) {
        $state->transaction(r => sub {
            my ($state, $data) = @_;

            $wait = 0 if $data->aggregators->{'test_aggregator'};
        });

        sleep 0.2 if $wait;
    }

    my $child1 = child {
        my $w = Atomic::Pipe->write_fifo($fifo_file);
        for (1 .. 1000) {
            $w->write_message(encode_json({child => 1, count => $_}));
        }
    };

    my $child2 = child {
        my $w = Atomic::Pipe->write_fifo($fifo_file);
        for (1 .. 1000) {
            $w->write_message(encode_json({child => 2, count => $_}));
        }
    };

    my $child3 = child {
        my $w = Atomic::Pipe->write_fifo($fifo_file);
        for (1 .. 1000) {
            $w->write_message(encode_json({child => 3, count => $_}));
        }
    };

    $child1->wait();
    $child2->wait();
    $child3->wait();

    my $reader = Test2::Harness::Util::File::JSONL->new(name => $out_file);

    my $params = {
        cnt        => $cnt,
        wdir       => $wdir,
        state_file => $state_file,
        fifo_file  => $fifo_file,
        out_file   => $out_file,
        state      => $state,
        agg        => $agg,
        reader     => $reader,
    };

    $callback->(%$params);

    return $params;
}

my $ret = produce_output {
    my %params = @_;
    my $agg = $params{agg};

    my $w = Atomic::Pipe->write_fifo($params{fifo_file});
    $w->write_message('TERMINATE');
    $agg->wait;
    is($agg->exit, 0, "Exited with no errors");
};

my @items = $ret->{reader}->read;
is(pop(@items), undef, "Last item was undef");
@items = sort { $a->{child} <=> $b->{child} || $a->{count} <=> $b->{count} } @items;
is(
    \@items,
    [
        (map { {child => 1, count => $_ } } 1 .. 1000),
        (map { {child => 2, count => $_ } } 1 .. 1000),
        (map { {child => 3, count => $_ } } 1 .. 1000),
    ],
    "got expected items"
);

$ret = produce_output {
    my %params = @_;
    my $agg = $params{agg};

    $agg->kill('TERM');
    $agg->wait;
    is(parse_exit($agg->exit)->{signame}, 'TERM', "Exited with sigterm");
};

@items = $ret->{reader}->read;
is(pop(@items), undef, "Last item was undef");

is(
    pop(@items),
    {
        facet_data => {
            info => [{
                tag     => 'AGG  SIG',
                details => '(AGGREGATOR) got SIGTERM',
            }]
        }
    },
    "Got signal event at the end before the undef"
);

@items = sort { $a->{child} <=> $b->{child} || $a->{count} <=> $b->{count} } @items;
is(
    \@items,
    [
        (map { {child => 1, count => $_ } } 1 .. 1000),
        (map { {child => 2, count => $_ } } 1 .. 1000),
        (map { {child => 3, count => $_ } } 1 .. 1000),
    ],
    "got expected items"
);

done_testing;
