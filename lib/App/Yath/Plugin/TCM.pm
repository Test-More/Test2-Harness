package App::Yath::Plugin::TCM;
use strict;
use warnings;

use parent 'App::Yath::Plugin';

sub options {
    my $class = shift;
    my ($cmd, $settings) = @_;

    return (
        {
            spec => 'tcm=s@',
            used_by => {runner => 1, jobs => 1},

            action => sub {
                my ($opt, $arg) = @_;
                push @{$settings->{plugins}->{$class}} => $arg;
            },

            section => 'Harness Options',
            usage   => ['--tcm path/to/tests'],
            summary => ["Run TCM tests from the path", "Can be specified multiple times"],

            long_desc => "This will tell Test2::Harness to handle TCM tests. Any test file matching /tcm.t\$/ will be excluded automatically in favor of handling the tests internally. Note that tcm tests inside your search path will normally be found automatically and run",
        },
    );
}

sub find_files {
    my $class = shift;
    my ($run) = @_;

    my @search = @{$run->plugins->{$class}};

    unless(@search) {
        my @dirs = grep { -d $_ } @{$run->search};
        require File::Find;
        File::Find::find(
            sub {
                return unless -d $_;
                return unless $File::Find::name =~ m{TestsFor$};
                push @search => $File::Find::name;
            },
            @dirs
        ) if @dirs;
    }

    return unless @search;

    my @libs = (File::Spec->rel2abs('t/lib'));

    my (@files, @dirs);
    for my $item (@search) {
        push @files => Test2::Harness::Util::TestFile->new(
            file => $item,
            queue_args => [
                via => ['Fork::TCM', 'Open3::TCM'],
                libs => \@libs,
            ],
        ) and next if -f $item;
        push @dirs => $item and next if -d $item;
        die "'$item' does not appear to be either a file or a directory.\n";
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';
                    return unless -f $_ && m/\.pm$/;
                    push @files => Test2::Harness::Util::TestFile->new(
                        file => $File::Find::name,
                        queue_args => [
                            via  => ['Fork::TCM', 'Open3::TCM'],
                            libs => \@libs,
                        ],
                    );
                },
            },
            @dirs,
        );
    }

    return @files;
}

sub pre_init {
    my $class = shift;
    my ($cmd, $settings) = @_;

    push @{$settings->{exclude_patterns}} => "(tcm|TCM)\\.t\$";
    $settings->{plugins}->{$class} ||= [];

    1;
}

sub block_default_search {
    my $class = shift;
    my ($settings) = @_;

    return 1 if @{$settings->{plugins}->{$class}};
    return 0;
}

1;
