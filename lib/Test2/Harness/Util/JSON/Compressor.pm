package Test2::Harness::Util::JSON::Compressor;
use strict;
use warnings;

use Importer Importer => 'import';

our @EXPORT_OK = qw/compress_json uncompress_json/;

my (@SPECIAL, %SPECIAL, $START_BYTE, $END_BYTE);

my $count = 128;
for my $item (<DATA>) {
    chomp($item);
    push @SPECIAL => $item;
    my $byte = pack("C", $count++);
    $SPECIAL{$item} = $byte;
    $SPECIAL{$byte} = $item;
    $START_BYTE //= $byte;
    $END_BYTE = $byte;
}

my $COMPRESS_REGEX = '(' . join('|' => map { "\Q$_\E"} @SPECIAL) . ')';

sub compress_json {
    $_[0] =~ s[$COMPRESS_REGEX][$SPECIAL{$1}]eg;
}

sub uncompress_json {
    $_[0] =~ s/([${START_BYTE}-${END_BYTE}])/$SPECIAL{$1}/eg;
}

1;

__DATA__
null
Test2::Harness::
Test2::
","
":"
},{
"about":
"assert":
"assert_count":
"buffered":
"children":
"cid":
"collapse":
"count":
"data":
"debug":
"details":
"eid":
"errors":
"event_id":
"fail":
"frame":
"from_harness":
"from_line":
"from_message":
"from_stream":
"from_tap":
"harness":
"header":
"hid":
"hubs":
"info":
"ipc":
"job_id":
"job_try":
"level":
"mark_tail":
"name":
"nested":
"no_collapse":
"no_debug":
"package":
"parent":
"pass":
"pid":
"plan":
"raw":
"rows":
"run_id":
"sanitize":
"skip":
"stamp":
"stream":
"table":
"tag":
"tid":
"trace":
"uuid":
