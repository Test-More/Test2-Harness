package Test2::Harness::Runner::DemandLoader;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;
use Test2::Harness::Util qw/open_file file2mod mod2file/;

use Test2::Harness::Util::HashBase qw/-files +inc_hook/;

sub import {
    my $class = shift;
    my ($load_from) = @_;

    return unless $load_from;

    my $one = $class->new();
    $one->load_from($load_from) if $load_from;
    $one->start;
}

sub init {
    my $self = shift;
    $self->{+FILES} //= {};
}

sub load_from {
    my $self = shift;
    my ($list) = @_;

    my $fh = open_file($list, '<');

    for my $line (<$fh>) {
        chomp($line);
        my ($file, @subs) = split /\s+/, $line;
        $self->{+FILES}->{$file} = \@subs;
    }
}

sub line_for_mod {
    my $self = shift;
    my ($mod) = @_;
    return $self->line_for_file(mod2file($mod), $mod);
}

sub line_for_file {
    my $self = shift;
    my ($file, $mod) = @_;
    $mod //= file2mod($file);

    require $file unless $INC{$file};

    return "$file import\n" if $mod->can('import');
    return "$file\n";
}

sub start {
    my $self = shift;

    $self->stop;
    my $inc_hook = $self->inc_hook;
    unshift @INC => $inc_hook;
}

sub stop {
    my $self = shift;
    my $inc_hook = $self->inc_hook;
    @INC = grep { ref($_) ne 'CODE' || $_ != $inc_hook } @INC;
}

our $AUTOLOAD;
sub inc_hook {
    my $self = shift;

    weaken($self);

    return $self->{+INC_HOOK} //= sub {
        my ($this, $file) = @_;

        my $spec = $self->{+FILES}->{$file} or return;

        my $mod = file2mod($file);
        $INC{$file} = __FILE__;

        my $real_load = sub {
            delete $INC{$file};
            delete $self->{+FILES}->{$file};

            {
                no strict 'refs';
                no warnings 'redefine';
                my $stash = \%{"$mod\::"};
                delete $stash->{AUTOLOAD};
                delete $stash->{$_} for @$spec;
            }

            require $file;
        };

        my $autosub = sub {
            my $name = $AUTOLOAD;
            $name =~ s/^.*:://;
            return if $name eq 'DESTROY';

            $real_load->();

            my $sub = $mod->can($name) or croak "Can't locate object method \"$name\" via package \"$mod\"";
            goto &$sub;
        };
        { no strict 'refs'; *{"$mod\::AUTOLOAD"} = $autosub }

        for my $sub (@$spec) {
            my $ref = sub {
                $real_load->();
                my $real = $mod->can($sub) or croak "Can't locate object method \"$sub\" via package \"$mod\"";
                goto &$real;
            };
            { no strict 'refs'; *{"$mod\::$sub"} = $ref };
        }

        return (\"1;");
    };
}

1;
