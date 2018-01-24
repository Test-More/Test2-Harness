package Test2::Harness::UI::Schema::Result::Run;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('runs');
__PACKAGE__->add_columns(qw/run_ui_id feed_ui_id facet_ui_id run_id permissions/);
__PACKAGE__->set_primary_key('run_ui_id');

__PACKAGE__->belongs_to(feed => 'Test2::Harness::UI::Schema::Result::Feed', 'feed_ui_id');
__PACKAGE__->belongs_to(facet => 'Test2::Harness::UI::Schema::Result::Facet', 'facet_ui_id');

__PACKAGE__->has_many(jobs => 'Test2::Harness::UI::Schema::Result::Job', 'run_ui_id');


sub user { shift->feed->user }

1;
