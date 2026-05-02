package App::Yath2::Plugin::TestPlugin;
use strict;
use warnings;

use Test2::Harness2::Util::HashBase qw/-foo/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Scalar::Util qw/blessed/;

use parent 'App::Yath2::Plugin';

print "TEST PLUGIN: Loaded Plugin\n";

sub duration_data {
    my $self = shift;

    print "TEST PLUGIN: duration_data\n";

    return {
        't/Yath/integration/plugin/a.tx'    => 'short',
        't/Yath/integration/plugin/b.tx'    => 'medium',
        't/Yath/integration/plugin/c.tx'    => 'medium',
        't/Yath/integration/plugin/d.tx'    => 'medium',
        't/Yath/integration/plugin/test.tx' => 'long',
    };
}

sub get_coverage_tests {
    my $self = shift;
    my ($settings, $changes) = @_;

    my $stype = ref($settings);
    my $type = ref($changes);
    my $count = keys %$changes;

    print "TEST PLUGIN: get_coverage_tests($stype, $type($count))\n";

    return [
        't/Yath/integration/plugin/a.tx',
        't/Yath/integration/plugin/b.tx',
        't/Yath/integration/plugin/c.tx',
        't/Yath/integration/plugin/d.tx',
        't/Yath/integration/plugin/test.tx',
    ];
}

sub changed_files {
    my $self = shift;
    my ($settings) = @_;
    my $type = ref($settings);

    print "TEST PLUGIN: changed_files($type)\n";

    return (
        't/Yath/integration/plugin/a.tx',
        't/Yath/integration/plugin/b.tx',
        't/Yath/integration/plugin/c.tx',
        't/Yath/integration/plugin/d.tx',
        't/Yath/integration/plugin/test.tx',
    );
}

sub sort_files_2 {
    my $self = shift;
    my %params = @_;

    die "self is not an instance! ($self)" unless blessed($self);

    my $settings = $params{settings} or die "NO SETTINGS!";
    my $files = $params{files};

    my %rank = (
        test => 1,
        c    => 2,
        b    => 3,
        a    => 4,
        d    => 5,
    );

    my @files = sort {
        my $an = $a->file;
        my $bn = $b->file;
        $an =~ s/^.*\W(\w+)\.tx$/$1/;
        $bn =~ s/^.*\W(\w+)\.tx$/$1/;
        $rank{$an} <=> $rank{$bn};
    } @$files;

    return @files;
};

sub munge_files {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    print "TEST PLUGIN: munge_files\n";
    return;
}

sub munge_search {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my ($search, $default_search) = @_;

    print "TEST PLUGIN: munge_search\n";

    @$search = ();

    my $path = __FILE__;
    $path =~ s{lib.{1,2}App.{1,2}Yath.{1,2}Plugin.{1,2}TestPlugin\.pm$}{}g;

    @$default_search = ($path);

    return;
}

sub claim_file {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my ($file) = @_;
    print "TEST PLUGIN: claim_file $file\n";

    if ($file =~ /\.tx/) {
        require App::Yath2::TestFile;
        return App::Yath2::TestFile->new(file => $file);
    }

    return;
}


sub finish          { die "Should not be called" }
sub finalize        { die "Should not be called" }
sub inject_run_data { die "Should not be called" }
sub handle_event    { die "Should not be called" }
sub setup           { die "Should not be called" }
sub teardown        { die "Should not be called" }

1;
