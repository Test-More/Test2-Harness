package App::Yath::Plugin::SelfTest;
use strict;
use warnings;

use Test2::Harness::Util::TestFile;

use IPC::Cmd qw/can_run/;
use parent 'App::Yath::Plugin';

sub find_files {
    my ($plugin, $run, $search) = @_;

    return if ($search && !grep { m{^(./)?t2(/non_perl(/(.*)?)?)?} } @$search);

    my @out;

    if (can_run('/usr/bin/bash')) {
        push @out => Test2::Harness::Util::TestFile->new(file => "t2/non_perl/test.sh");
    }

    if (can_run('gcc')) {
        system('gcc', '-o' => 't2/non_perl/test.binary', 't2/non_perl/test.c') and die "Failed to compile t2/non_perl/test.c";
        push @out => Test2::Harness::Util::TestFile->new(file => "t2/non_perl/test.binary");
    }

    return @out;
}

1;
