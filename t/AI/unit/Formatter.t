use Test2::V0;
use App::Yath2::Formatter;

ok(App::Yath2::Formatter->can('produces_artifact'), 'class method produces_artifact exists');
is(App::Yath2::Formatter->produces_artifact, 1, 'default produces_artifact returns 1');

# Subclass without convert_item dies.
{

    package T::F::Bad;
    use parent 'App::Yath2::Formatter';
}
my $f = T::F::Bad->new;
like(dies { $f->append({}) }, qr/convert_item/, 'unimplemented convert_item dies');

# Concrete formatter that joins items as "id\n".
{

    package T::F::Good;
    use parent 'App::Yath2::Formatter';
    sub convert_item { my (undef, $i) = @_; return "$i->{id}\n" }
}
my $g = T::F::Good->new;

# Return-string mode.
is($g->append({id => 'a'}), "a\n", 'append returns string when no out_fh');

# Write-to-fh mode.
open my $mfh, '>', \my $buf or die;
$g->append({id => 'b'}, out_fh => $mfh);
$g->append({id => 'c'}, out_fh => $mfh);
close $mfh;
is($buf, "b\nc\n", 'append writes to out_fh when supplied');

# List input.
is($g->convert([{id => 'x'}, {id => 'y'}]), "x\ny\n", 'list input');

# List input with out_fh.
open my $lfh, '>', \my $lbuf or die;
$g->convert([{id => 'p'}, {id => 'q'}], out_fh => $lfh);
close $lfh;
is($lbuf, "p\nq\n", 'convert writes to out_fh when supplied');

# Filehandle input.
open my $ifh, '<', \(my $src = qq[{"id":"q"}\n{"id":"r"}\n]) or die;
open my $ofh, '>', \my $out                                  or die;
$g->feed(in_fh => $ifh, out_fh => $ofh);
close $ofh;
is($out, "q\nr\n", 'feed reads JSONL from in_fh, writes to out_fh');

# feed validates fh args
like(dies { $g->feed(out_fh => $mfh) }, qr/in_fh/i,  'feed requires in_fh');
like(dies { $g->feed(in_fh  => $ifh) }, qr/out_fh/i, 'feed requires out_fh');

done_testing;
