package App::Yath::Plugin::Test;
use strict;
use warnings;

our $VERSION = '0.001016';

use parent 'App::Yath::Plugin';

my %CALLS;

sub options              { push @{$CALLS{options}}              => [@_]; return }
sub pre_init             { push @{$CALLS{pre_init}}             => [@_]; return }
sub post_init            { push @{$CALLS{post_init}}            => [@_]; return }
sub find_files           { push @{$CALLS{find_files}}           => [@_]; return }
sub block_default_search { push @{$CALLS{block_default_search}} => [@_]; return }

sub CLEAR_CALLS { %CALLS = () }

sub GET_CALLS {
    return { %CALLS }
}

die "Should not see this";

1;
