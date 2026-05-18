use Test2::V0;
use App::Yath2::Formatter::Tty;

isa_ok('App::Yath2::Formatter::Tty', ['App::Yath2::Formatter']);
my $f = App::Yath2::Formatter::Tty->new;
is($f->produces_artifact, 0,         'tty never persisted');
is($f->color_mode,        'auto',    'color_mode default');
is($f->theme,             'default', 'theme default');

# Without out_fh, auto mode returns uncolored bytes (no fh to test isatty).
my $item     = {facet_data => {assert => {pass => 1, details => 'one'}}};
my $out_auto = $f->append($item);
unlike($out_auto, qr/\e\[/, 'auto mode without fh: no ANSI');
like($out_auto, qr/PASS:/, 'tag still present');

# color_mode=always returns ANSI even without fh
my $f2         = App::Yath2::Formatter::Tty->new(color_mode => 'always');
my $out_always = $f2->append($item);
like($out_always, qr/\e\[32m/, 'green for PASS in always mode');
like($out_always, qr/\e\[0m/,  'reset present');

# color_mode=never returns no ANSI
my $f3 = App::Yath2::Formatter::Tty->new(color_mode => 'never');
unlike($f3->append($item), qr/\e\[/, 'never mode: no ANSI');

# FAIL tag colors red
my $fail = {facet_data => {assert => {pass => 0, details => 'oops'}}};
like($f2->append($fail), qr/\e\[31m/, 'red for FAIL');

# convert with list input + out_fh
open my $fh, '>', \my $buf or die "open: $!";
$f2->convert([$item], out_fh => $fh);
close $fh;
like($buf, qr/\e\[32mPASS:\e\[0m/, 'convert colorizes when written to fh');

# feed with JSONL input
my $src = qq[{"facet_data":{"assert":{"pass":1,"details":"q"}}}\n];
open my $ifh, '<', \$src        or die "open: $!";
open my $ofh, '>', \my $out_buf or die "open: $!";
$f2->feed(in_fh => $ifh, out_fh => $ofh);
close $ofh;
like($out_buf, qr/\e\[32m/, 'feed colorizes when always');

# amnesty form (! PASS !:) is colorized with PASS palette entry
my $amnesty_item = {
    facet_data => {
        assert  => {pass => 0, details => 'todo test'},
        amnesty => [{tag => 'TODO', details => 'not yet'}],
    }
};
my $amnesty_out = $f2->append($amnesty_item);
like($amnesty_out, qr/\e\[32m! PASS !:\e\[0m/, 'amnesty form colorized with PASS color');
like($amnesty_out, qr/\e\[35mTODO:\e\[0m/,     'TODO tag colorized magenta');

# HARNESS tag colors cyan
my $harness_item = {facet_data => {harness_job_start => {details => 'foo.t started'}}};
like($f2->append($harness_item), qr/\e\[36mHARNESS:\e\[0m/, 'HARNESS tag colorized cyan');

# HALT tag colors bright red
my $halt_item = {facet_data => {control => {halt => 1, details => 'bail'}}};
like($f2->append($halt_item), qr/\e\[1;31mHALT:\e\[0m/, 'HALT tag colorized bright red');

# convert without out_fh returns colorized bytes (always mode)
my $ret = $f2->convert([$item]);
like($ret, qr/\e\[32m/, 'convert returns colorized bytes in always mode');

# indented lines (subtest children) keep indent outside the color span
my $child       = {facet_data => {assert => {pass => 1, details => 'child'}}};
my $parent_item = {
    facet_data => {
        assert => {pass     => 1, details => 'outer', no_debug => 1},
        parent => {children => [$child]},
    }
};
my $parent_out = $f2->append($parent_item);
like($parent_out, qr/  \e\[32mPASS:\e\[0m child/, 'indent preserved before color span on child line');

done_testing;
