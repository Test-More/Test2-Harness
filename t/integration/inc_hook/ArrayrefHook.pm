package ArrayrefHook;
use strict;
use warnings;

unshift @INC, [sub { return }];

1;
