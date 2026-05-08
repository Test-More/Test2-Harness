package FakeHook;
use strict;
use warnings;

# INC is a special identifier that lives in main::, hence the FQN.
sub FakeHook::INC { return }

unshift @INC, bless({}, __PACKAGE__);

1;
