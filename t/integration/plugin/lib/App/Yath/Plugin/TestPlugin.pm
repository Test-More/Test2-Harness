package App::Yath::Plugin::TestPlugin;
use strict;
use warnings;

use Test2::Harness::Util::HashBase qw/-foo/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Scalar::Util qw/blessed/;

use parent 'App::Yath::Plugin';

print "TEST PLUGIN: Loaded Plugin\n";

sub duration_data {
    my $self = shift;

    print "TEST PLUGIN: duration_data\n";

    return {
        't/integration/plugin/a.tx'    => 'short',
        't/integration/plugin/b.tx'    => 'medium',
        't/integration/plugin/c.tx'    => 'medium',
        't/integration/plugin/d.tx'    => 'medium',
        't/integration/plugin/test.tx' => 'long',
    };
}

sub coverage_data {
    my $self = shift;
    my ($changes) = @_;

    my $type = ref($changes);

    print "TEST PLUGIN: coverage_data($type:[" . join(",", sort @$changes) . "])\n";

    return [
        't/integration/plugin/a.tx',
        't/integration/plugin/b.tx',
        't/integration/plugin/c.tx',
        't/integration/plugin/d.tx',
        't/integration/plugin/test.tx',
    ];
}

sub changed_files {
    my $self = shift;
    my ($settings) = @_;
    my $type = ref($settings);

    print "TEST PLUGIN: changed_files($type)\n";

    return (
        't/integration/plugin/a.tx',
        't/integration/plugin/b.tx',
        't/integration/plugin/c.tx',
        't/integration/plugin/d.tx',
        't/integration/plugin/test.tx',
    );
}

sub sort_files {
    my $self = shift;

    die "self is not an instance! ($self)" unless blessed($self);

    my (@files) = @_;

    my %rank = (
        test => 1,
        c    => 2,
        b    => 3,
        a    => 4,
        d    => 5,
    );

    @files = sort {
        my $an = $a->file;
        my $bn = $b->file;
        $an =~ s/^.*\W(\w+)\.tx$/$1/;
        $bn =~ s/^.*\W(\w+)\.tx$/$1/;
        $rank{$an} <=> $rank{$bn};
    } @files;

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
        require Test2::Harness::TestFile;
        return Test2::Harness::TestFile->new(file => $file);
    }

    return;
}

sub inject_run_data {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my %params = @_;
    print "TEST PLUGIN: inject_run_data\n";

    my $fields = $params{fields};
    push @$fields => {name => 'test_plugin', details => 'foo', raw => 'bar', data => 'baz'};

    return;
}

my $seen = 0;
sub handle_event {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my ($event) = @_;
    print "TEST PLUGIN: handle_event\n" unless $seen++;

    if(my $run = $event->facet_data->{harness_run}) {
        print "FIELDS: " . encode_json($run->{fields}) . "\n";
    }

    return;
}

sub finish {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my %args = @_;

    print "TEST PLUGIN: finish " . join(', ' => map { "$_ => " . (ref($args{$_}) || $args{$_} // '?') } sort keys %args) . "\n";
    return;
}

sub setup {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my ($settings) = @_;
    print "TEST PLUGIN: setup " . ref($settings) . "\n";

    $self->shellcall(
        $settings,
        'testplug',
        $^X, '-e', 'print STDERR "STDERR WRITE\n"; print STDOUT "STDOUT WRITE\n";',
    );

    return;
}

sub teardown {
    my $self = shift;
    die "self is not an instance! ($self)" unless blessed($self);
    my ($settings) = @_;
    print "TEST PLUGIN: teardown " . ref($settings) . "\n";
    return;
}

1;
