package App::Yath::Command::upload;
use strict;
use warnings;

our $VERSION = '2.000004';

use Test2::Harness::Util::Deprecated(
    replaced => ['App::Yath::Command::client::publish', 'App::Yath::Command::db::publish'],
    core => 1,
);

1;

__END__

=head1 POD IS AUTO-GENERATED
