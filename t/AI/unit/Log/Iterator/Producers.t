use Test2::V0;
use App::Yath2::Log::Iterator::Producers;
use App::Yath2::Log::Producer::Run;

my @descriptors = map { App::Yath2::Log::Producer::Run->new(id => $_, state => 'partial', log => undef); } qw/a b c/;

# next() drives the iterator
my $idx  = 0;
my $iter = App::Yath2::Log::Iterator::Producers->new(
    next_cb => sub { return $descriptors[$idx++] },
);

isa_ok($iter, ['App::Yath2::Log::Iterator::Producers']);
my $first = $iter->next;
is($first->id,      'a',   'first descriptor');
is($iter->next->id, 'b',   'second');
is($iter->next->id, 'c',   'third');
is($iter->next,       undef, 'EOF returns undef');
my $idx_at_eof = $idx;
is($iter->next,       undef, 'subsequent next still undef (done sticky)');
is($idx, $idx_at_eof, 'callback not reinvoked after sticky EOF');

# all() drains a fresh iterator
$idx = 0;
my $iter2 = App::Yath2::Log::Iterator::Producers->new(
    next_cb => sub { return $descriptors[$idx++] },
);
my @all = $iter2->all;
is(scalar(@all),          3,           'all returns three');
is([map { $_->id } @all], [qw/a b c/], 'in order');

# constructor validation
like(
    dies { App::Yath2::Log::Iterator::Producers->new(next_cb => "not a code ref") },
    qr/next_cb/i,
    'rejects non-CODE next_cb',
);
like(
    dies { App::Yath2::Log::Iterator::Producers->new() },
    qr/next_cb/i,
    'rejects missing next_cb',
);

done_testing;
