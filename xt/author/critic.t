use strict;
use warnings;

use Test2::Require::AuthorTesting;
use Test::Perl::Critic;

all_critic_ok('lib', 'release-scripts', 't', 't2', 'xt');
