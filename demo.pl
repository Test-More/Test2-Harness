#!/usr/bin/perl

use strict;
use warnings;

use Tickit::Console;
use Tickit::Widgets 0.30 qw( Frame=0.32 );

use String::Tagged;

my $globaltab;

# Input History State
my $idx = -1;
my $set;
my @log;
my $console = Tickit::Console->new(
    on_line => sub {
        my ($self, $line) = @_;

        $idx = -1;
        $set = undef;

        if ($line eq "quit") {
            exit(0);
        }
        else {
            unshift @log => $line;
            $globaltab->add_line("<INPUT>: $line");
        }
    },
);

$console->bind_key(
    "Tab" => sub {
        my ($c, $key) = @_;

        my $t = $c->find_child('first', undef, where => sub { $_ && $_->isa('Tickit::Widget::Entry') });
        my $p = $t->make_popup_at_cursor(0, 0, 100, 100);

        use Tickit::Widget::Frame;
        use Tickit::Widget::Static;
        my $frame = Tickit::Widget::Frame->new(
            style => {linetype => "single"},
        );

        $frame->set_child(Tickit::Widget::Static->new(
            text   => "Hello, world",
            align  => "centre",
            valign => "middle",
        ));

        $frame->set_window($p);

        use Data::Dumper;
        local $Data::Dumper::Maxdepth = 2;
        print Dumper($c);
    }
);

# New up/down
$console->bind_key("M-Up"   => sub { shift->active_tab->widget->scroll(-1) });
$console->bind_key("M-Down" => sub { shift->active_tab->widget->scroll(1) });

# History Up
$console->bind_key("Up"   => sub {
    my $c = shift;

    my $e = $c->find_child('first', undef, where => sub { $_ && $_->isa('Tickit::Widget::Entry') });

    if ($idx == -1) {
        $set //= $e->text // '';
        $e->key_end_of_line;
    }

    if ($log[$idx + 1]) {
        $idx++;
        $e->set_text($log[$idx]);
        $e->key_end_of_line;
    }
});

# History Down
$console->bind_key("Down"   => sub {
    my $c = shift;

    my $e = $c->find_child('first', undef, where => sub { $_ && $_->isa('Tickit::Widget::Entry') });

    return if $idx < 0;
    $idx--;

    if ($idx < 0) {
        $idx = -1;
        $e->set_text($set // '');
        $e->key_end_of_line;
        $set = undef;
    }
    else {
        $e->set_text($log[$idx]);
        $e->key_end_of_line;
    }
});

$globaltab = $console->add_tab(name => "GLOBAL");

Tickit->new(root => $console)->run;
