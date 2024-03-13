package TestPlugin;
use strict;
use warnings;

use parent 'App::Yath::Plugin';

sub munge_files {
    my $self = shift;
    my ($files, $settings) = @_;

    for my $file (@$files) {
        next unless $file->file =~ m/(AAA|BBB)\.tx$/i;
        my $stage = uc($1);
        $file->set_stage($stage);
    }
}

1;
