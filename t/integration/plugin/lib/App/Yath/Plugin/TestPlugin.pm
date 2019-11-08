package App::Yath::Plugin::TestPlugin;
use strict;
use warnings;

use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'App::Yath::Plugin';

print "TEST PLUGIN: Loaded Plugin\n";

sub munge_files {
    print "TEST PLUGIN: munge_files\n";
    return;
}

sub munge_search {
    my $self = shift;
    my ($run, $search, $default_search) = @_;

    print "TEST PLUGIN: munge_search\n";

    @$search = ();

    my $path = __FILE__;
    $path =~ s{lib.{1,2}App.{1,2}Yath.{1,2}Plugin.{1,2}TestPlugin\.pm$}{}g;

    @$default_search = ($path);

    return;
}

sub claim_file {
    my $self = shift;
    my ($file) = @_;
    print "TEST PLUGIN: claim_file $file\n";

    if ($file =~ /\.tx/) {
        require Test2::Harness::TestFile;
        return Test2::Harness::TestFile->new(file => $file);
    }

    return;
}

sub inject_run_data {
    my $self = shift;
    my %params = @_;
    print "TEST PLUGIN: inject_run_data\n";

    my $fields = $params{fields};
    push @$fields => {name => 'test_plugin', details => 'foo', raw => 'bar', data => 'baz'};

    return;
}

my $seen = 0;
sub handle_event {
    my $self = shift;
    my ($event) = @_;
    print "TEST PLUGIN: handle_event\n" unless $seen++;

    if(my $run = $event->facet_data->{harness_run}) {
        print "FIELDS: " . encode_json($run->{fields}) . "\n";
    }

    return;
}

sub finish {
    my $self = shift;
    my ($settings) = @_;
    print "TEST PLUGIN: finish " . ref($settings) . "\n";
    return;
}

1;
