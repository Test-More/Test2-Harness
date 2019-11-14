package TestPreload;
use strict;
use warnings;
use Time::HiRes qw/sleep time/;
use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness::Runner::Preload;

my $dir = tempdir(CLEANUP => 1);
my $TRIGGER = File::Spec->catfile($dir, 'trigger');

file_stage sub {
    my ($file) = @_;

    return uc($1) if $file =~ m/(AAA|BBB)\.tx$/i;

    return;
};

stage AAA => sub {
    preload 'AAA';

    stage BBB => sub {
        preload 'BBB';
    };
};

our %HOOKS;
stage CCC => sub {
    $HOOKS{INIT} = [time(), $$];
    pre_fork sub   { $HOOKS{PRE_FORK}   = [time(), $$] };
    post_fork sub  { $HOOKS{POST_FORK}  = [time(), $$] };
    pre_launch sub { $HOOKS{PRE_LAUNCH} = [time(), $$] };

    preload 'CCC';
};

stage FAST => sub {
    eager;
    default;

    preload 'FAST';

    preload sub {
        eval <<"        EOT" or die $@;
#line ${ \__LINE__ } "${ \__FILE__ }"
END {
    return unless \$0 =~ m/slow\.tx/;
    open(my \$fh, '>', "$TRIGGER") or die "XXX";
    print \$fh "\n";
    close(\$fh);
}
1;
        EOT
    };

    stage SLOW => sub {
        preload sub {
            print "$0 pending...\n";
            use Carp qw/cluck/;
            local $SIG{ALRM} = sub { cluck "oops"; exit 255 };
            alarm 5;
            until (-f $TRIGGER) {
                print "$0 Waiting...\n";
                sleep 0.2
            }
        };
    };
};

1;
