use Test2::V0;
use App::Yath2::Formatter::Txt;

my $f = App::Yath2::Formatter::Txt->new;
is($f->produces_artifact, 0, 'txt experimental: not yet cacheable');
isa_ok($f, ['App::Yath2::Formatter']);

# assert
my $ok = {facet_data => {assert => {details => 'passed test'}}};
like($f->convert_item($ok), qr/passed test/, 'renders assert detail');

# info
my $info = {facet_data => {info => [{details => 'banner'}]}};
like($f->convert_item($info), qr/banner/, 'renders info detail');

# Multi-info
my $multi = {facet_data => {info => [{details => 'line1'}, {details => 'line2'}]}};
my $bytes = $f->convert_item($multi);
like($bytes, qr/line1/, 'first info line');
like($bytes, qr/line2/, 'second info line');

# No facets
is($f->convert_item({facet_data => {}}), '', 'no facets => empty');
is($f->convert_item({}),                 '', 'no facet_data => empty');

done_testing;
