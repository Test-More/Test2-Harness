#!perl

use strict;
use warnings;
use Test::More;

# note: this is going to fail if IOT is defined before...
# %SIG = %SIG; will introduce a flapping behavior

$SIG{'ABRT'} = sub {
  my ($sig) = @_;
  is $sig, 'ABRT';
};

kill 'ABRT', $$;

done_testing;
