package Test2::Harness::UI::ControllerRole::HTML;
use strict;
use warnings;

use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;

use Importer Importer => 'import';

our @EXPORT = qw/wrap_content/;

sub wrap_content {
    my $self = shift;
    my ($content) = @_;

    my $template = share_dir('templates/main.tx');

    my $tx = Text::Xslate->new();
    return $tx->render($template, {
        content => mark_raw($content),
        title   => $self->title,
    });
}

1;
