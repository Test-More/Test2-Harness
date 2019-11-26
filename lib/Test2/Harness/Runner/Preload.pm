package Test2::Harness::Runner::Preload;
use strict;
use warnings;

our $VERSION = '1.000000';

use Carp qw/croak/;

use Test2::Harness::Runner::Preload::Stage();

sub import {
    my $class = shift;
    my $caller = caller;

    my %exports;

    my $instance = $class->new;

    $exports{TEST2_HARNESS_PRELOAD} = sub { $instance };

    $exports{stage} = sub {
        my ($name, $code) = @_;
        my @caller = caller();
        $instance->build_stage(
            name   => $name,
            code   => $code,
            caller => \@caller,
        );
    };

    $exports{eager} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_eager(1);
    };

    $exports{default} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        my $name = $stage->name;
        $instance->set_default_stage($name);
    };

    $exports{file_stage} = sub {
        my ($callback) = @_;
        my @caller = caller();
        croak "'file_stage' cannot be used under a stage" if @{$instance->stack};
        $instance->add_file_stage(\@caller, $callback);
    };

    for my $name (qw/pre_fork post_fork pre_launch/) {
        my $meth = "add_${name}_callback";
        $exports{$name} = sub {
            croak "No current stage" unless @{$instance->stack};
            my $stage = $instance->stack->[-1];
            $stage->$meth(@_);
        };
    }

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->add_to_load_sequence(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"$caller\::$name"} = $exports{$name};
    }
}

use Test2::Harness::Util::HashBase qw{
    <stage_list
    <stage_lookup
    <stack
    +default_stage
    +file_stage
};

sub init {
    my $self = shift;

    $self->{+STAGE_LIST} //= [];
    $self->{+STAGE_LOOKUP} //= {};

    $self->{+STACK} //= [];

    $self->{+FILE_STAGE} //= [];
}

sub build_stage {
    my $self = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness::Runner::Preload::Stage->new(
        stage_lookup => $self->{+STAGE_LOOKUP},
        %params,
    );

    my $stack = $self->{+STACK} //= [];
    push @$stack => $stage;

    my $ok = eval { $params{code}->($stage); 1 };
    my $err = $@;

    die "Mangled stack" unless @$stack && $stack->[-1] eq $stage;

    pop @$stack;

    die $err unless $ok;

    if (@$stack) {
        $stack->[-1]->add_child($stage);
    }
    else {
        $self->add_stage($stage, $caller);
    }

    return $stage;
}

sub add_stage {
    my $self = shift;
    my ($stage, $caller) = @_;

    $caller //= [caller()];

    my @all = ($stage, @{$stage->all_children});

    for my $item (@all) {
        my $name = $item->name;

        if (my $existing = $self->{+STAGE_LOOKUP}->{$name}) {
            $caller //= [caller()];
            my $ncaller = $item->frame;
            my $ecaller = $existing->frame;
            die <<"            EOT"
A stage named '$name' was already defined.
  First at  $ecaller->[1] line $ecaller->[2].
  Second at $ncaller->[1] line $ncaller->[2].
  Mixed at  $caller->[1] line $caller->[2].
            EOT
        }

        $self->{+STAGE_LOOKUP}->{$name} = $item;
    }

    push @{$self->{+STAGE_LIST}} => $stage;
}

sub merge {
    my $self = shift;
    my ($merge) = @_;

    my $caller = [caller()];

    for my $stage (@{$merge->{+STAGE_LIST}}) {
        $self->add_stage($stage, $caller);
    }

    push @{$self->{+FILE_STAGE}} => @{$merge->{+FILE_STAGE}};

    $self->{+DEFAULT_STAGE} //= $merge->default_stage;
}

sub add_file_stage {
    my $self = shift;
    my ($caller, $code) = @_;

    croak "Caller must be defined and an array" unless $caller && ref($caller) eq 'ARRAY';
    croak "Code must be defined and a coderef"  unless $code   && ref($code) eq 'CODE';

    push @{$self->{+FILE_STAGE}} => [$caller, $code];
}

sub file_stage {
    my $self = shift;
    my ($file) = @_;

    for my $cb (@{$self->{+FILE_STAGE}}) {
        my ($caller, $code) = @$cb;
        my $stage = $code->($file) or next;

        die "file_stage callback returned invalid stage: $stage at $caller->[1] line $caller->[2].\n"
            unless $self->{+STAGE_LOOKUP}->{$stage};

        return $stage;
    }

    return;
}

sub default_stage {
    my $self = shift;
    return $self->{+DEFAULT_STAGE} if $self->{+DEFAULT_STAGE};
    return $self->{+STAGE_LIST}->[0];
}

sub set_default_stage {
    my $self = shift;
    my ($name) = @_;

    croak "Default stage already set to $self->{+DEFAULT_STAGE}" if $self->{+DEFAULT_STAGE};
    $self->{+DEFAULT_STAGE} = $name;
}

sub eager_stages {
    my $self = shift;

    my %eager;

    for my $root (@{$self->{+STAGE_LIST}}) {
        for my $stage ($root, @{$root->all_children}) {
            next unless $stage->eager;
            $eager{$stage->name} = [map { $_->name } @{$stage->all_children}];
        }
    }

    return \%eager;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preload - DSL for building complex stage-based preload
tools.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
