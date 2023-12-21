package App::Yath::Command::console;
use strict;
use warnings;

our $VERSION = '2.000000';

use POSIX();

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +console
    <tabs
    +tickit
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::Term',
    'App::Yath::Options::Yath',
);

sub args_include_tests { 0 }

sub group { 'console' }

sub summary  { "Start a yath console" }

warn "FIXME";
sub description {
    return <<"    EOT";
    FIXME
    EOT
}

use Tickit::Console;
use Tickit::Widgets;
use String::Tagged;

sub init {
    my $self = shift;

    my $self->{+TABS} //= {};
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    my $tickit = $self->tickit();

    $self->{+TABS}->{foo} = $self->tickit_console->add_tab(name => 'foo');

    open(my $fh, "-|", q/perl -e 'my $c = 1; while (1) { print "$c: foo\n"; $c++; STDOUT->flush(); sleep 1 }'/);
    $tickit->watch_io(
        $fh,
        Tickit::IO_IN|Tickit::IO_HUP,
        sub {
            my $l = <$fh>;
            chomp($l);
            $self->{+TABS}->{foo}->append_line($l);
        }
    );

    $tickit->run;

    return 0;
}

sub tickit {
    my $self = shift;
    return $self->{+TICKIT} //= Tickit->new(root => $self->tickit_console());
}

sub tickit_console {
    my $self = shift;

    return $self->{+CONSOLE} if $self->{+CONSOLE};

    # Input History State
    my $idx = -1;
    my $set;
    my @log;
    my $console = Tickit::Console->new(
        on_line => sub {
            my ($c, $line) = @_;

            unshift @log => $line;

            use Text::ParseWords qw/shellwords/;
            my ($cmd, @args) = shellwords($line);

            $idx = -1;
            $set = undef;

            $self->{+TABS}->{'main'}->append_line( "> $line" );

            if ($line eq "quit" || $line eq 'exit') {
                $self->{+TICKIT}->stop;
            }

            if ($self->can("command_${line}")) {
            }
            else {
                my $text = String::Tagged->new_tagged("Invalid command\n", fg => 'red');
                $self->{+TABS}->{main}->append_line( $text );
            }
        },
    );

    # Control+D to stop
    $console->bind_key("C-d" => sub { print "\nControl + D pressed, exiting...\n"; $self->{+TICKIT}->stop });

    # New up/down
    $console->bind_key("M-Up"   => sub { shift->active_tab->widget->scroll(-1) });
    $console->bind_key("M-Down" => sub { shift->active_tab->widget->scroll(1) });

    $console->bind_key("M-Left"  => sub { shift->prev_tab });
    $console->bind_key("M-Right" => sub { shift->next_tab });

    my $warned = 0;

    # History Up
    $console->bind_key(
        "Up" => sub {
            my $c = shift;

            warn "Fixme: use \$c->entry" unless $warned++;
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
            else {
                print "\a";
            }
        }
    );

    # History Down
    $console->bind_key(
        "Down" => sub {
            my $c = shift;

            warn "Fixme: use \$c->entry" unless $warned++;
            my $e = $c->find_child('first', undef, where => sub { $_ && $_->isa('Tickit::Widget::Entry') });

            if ($idx < 0) {
                print "\a";
                return;
            }

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
        }
    );

    $self->{+TABS}->{'main'} = $console->add_tab(name => "Console");

    $SIG{__WARN__} = sub {
        my ($warn) = @_;
        if (my $tab = $self->{+TABS}->{'main'}) {
            chomp($warn);
            my $text = String::Tagged->new_tagged( "$warn\n", fg => 'yellow' );
            $tab->append_line( $text );
        }
        else {
            warn $@;
        }
    };

    return $self->{+CONSOLE} = $console;
}

1;
