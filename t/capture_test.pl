use Test::Builder::Formatter;
use Test::Builder;
use Test2::Formatter::Stream;
use Test2::V0;
use Test2::Tools::Subtest qw/subtest_streamed/;

my ($out1, $out2) = ('', '');
open(my $fh1, '>', \$out1) or die $!;
open(my $fh2, '>', \$out2) or die $!;

#Test::Builder->new->output($fh1);
#Test::Builder->new->failure_output($fh2);
#Test::Builder->new->todo_output($fh1);

sub my_fail {
    my $ctx = Test2::API::context();
    $ctx->fail(@_);
    $ctx->release;
}

sub my_pass {
    my $ctx = Test2::API::context();
    $ctx->pass(@_);
    $ctx->release;
}

ok(1, "pass");
print STDOUT "STDOUT A\n";
print STDERR "STDERR A\n";
ok(1, "pass");
system(qq{$^X -e 'print STDOUT "EXTERNAL STDOUT\n"'});
system(qq{$^X -e 'print STDERR "EXTERNAL STDERR\n"'});
ok(1, "pass");
print STDOUT "STDOUT B\n";
print STDERR "STDERR B\n";
my_fail("fail");

subtest AAA => sub {
    subtest BBB => sub {
        subtest CCC => sub {
            my_fail("fail");
            my_pass("ideal pass");
        };
    };
};

subtest_streamed xyz => sub {
    ok(1, "pass");
};

diag "diag message";

use Data::Dumper;
print 'ARGV: ' . Dumper(\@ARGV);

print 'STDIN: ' . join("" => <STDIN>) . "\n";

done_testing;

print $out1;
print STDERR $out2;
