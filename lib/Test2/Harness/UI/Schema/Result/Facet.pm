package Test2::Harness::UI::Schema::Result::Facet;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('facets');
__PACKAGE__->add_columns(qw/facet_ui_id event_ui_id facet_type facet_name facet_value/);
__PACKAGE__->set_primary_key('facet_ui_id');

__PACKAGE__->belongs_to(event => 'Test2::Harness::UI::Schema::Result::Event', 'event_ui_id');

__PACKAGE__->might_have(run => 'Test2::Harness::UI::Schema::Result::Run', 'facet_ui_id');

__PACKAGE__->might_have(job => 'Test2::Harness::UI::Schema::Result::Job', 'job_facet_ui_id');
__PACKAGE__->might_have(end => 'Test2::Harness::UI::Schema::Result::Job', 'end_facet_ui_id');

my %ALLOWED_TYPES = (
    'other'              => 1,
    'about'              => 1,
    'amnesty'            => 1,
    'assert'             => 1,
    'control'            => 1,
    'error'              => 1,
    'info'               => 1,
    'meta'               => 1,
    'parent'             => 1,
    'plan'               => 1,
    'trace'              => 1,
    'harness'            => 1,
    'harness_run'        => 1,
    'harness_job'        => 1,
    'harness_job_launch' => 1,
    'harness_job_start'  => 1,
    'harness_job_exit'   => 1,
    'harness_job_end'    => 1,
);

sub new {
    my $class = shift;
    my ($attrs) = @_;

    # If the facet name is one of the allowed types use it, otherwise 'other' is used.
    $attrs->{facet_type} ||= $ALLOWED_TYPES{$attrs->{facet_name}} ? $attrs->{facet_name} : 'other';

    my $new = $class->next::method($attrs);

    return $new;
}

1;
