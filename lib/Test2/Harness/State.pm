package Test2::Harness::State;
use strict;
use warnings;

our $VERSION = '1.000152';

use File::Spec;

use Test2::Harness::State::Instance;
use Test2::Harness::Settings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Util qw/mod2file clean_path/;

use parent 'Test2::Harness::IPC::SharedState';
use Test2::Harness::Util::HashBase(
    qw{
        <workdir

        +resources +resource_list
        +plugins   +plugin_list     +plugin_lookup
        +renderer  +renderer_list   +renderer_lookup
        +job_count
        +settings

        <observe
    },
);

sub state_class { 'Test2::Harness::State::Instance' }

sub clone {
    my $self = shift;
    my $copy = {%$self};
    delete $copy->{access_id};
    delete $copy->{access_pid};
    %$copy = (%$copy, @_) if @_;
    return bless($copy, blessed($self));
}

sub access_id  { $_[0]->_access->[0] }
sub access_pid { $_[0]->_access->[1] }
sub registered { $_[0]->_access->[2] }

sub _access {
    my $self = shift;

    my $id  = $self->{+ACCESS_ID};
    my $pid = $self->{+ACCESS_PID};

    if (defined $pid) {
        return [$id // $pid, $pid, $self->{+REGISTERED} ? 1 : 0] if $pid && $pid == $$;
    }

    if(defined($id) || defined($pid)) {
        delete $self->{+ACCESS_ID};
        delete $self->{+ACCESS_PID};
    }

    if (my $rpid = $self->{+REGISTERED}) {
        delete $self->{+REGISTERED} unless $rpid == $$;
    }

    return [$$, $$, $self->{+REGISTERED} ? 1 : 0];
}

sub init {
    my $self = shift;

    my $workdir    = $self->{+WORKDIR};
    my $state_file = $self->{+STATE_FILE};

    if ($workdir) {
        $state_file //= $self->{+STATE_FILE} //= File::Spec->catfile($workdir, 'state.json');
    }
    elsif ($state_file) {
        unless ($workdir) {
            my $real_path = clean_path($state_file); # Follow symlinks, etc
            my ($vol, $dir, $file) = File::Spec->splitpath($real_path);
            $workdir = $self->{+WORKDIR} //= File::Spec->catpath($vol, $dir);
        }
    }
    else {
        croak "You must specify either a 'workdir' or a 'state_file'";
    }

    croak "Invalid work dir '$workdir'" unless -d $workdir;

    $self->{+STATE_FILE} = clean_path($state_file);

    $self->SUPER::init();

    my @bad = grep { !$self->can(uc($_)) } keys %$self;
    croak "The following invalid keys were passed into the constructor: " . join(', ' => @bad)
        if @bad;

    $self->{+PLUGIN_LOOKUP} //= {};
}

sub sync_from_state {
    my $self = shift;
    my ($state) = @_;

    $self->SUPER::sync_from_state($state);

    $self->{+WORKDIR} = $state->{workdir};
}

sub init_state {
    my $self = shift;

    confess "Attempt to initialize state from an observer"
        if $self->{+OBSERVE};

    my $state = $self->SUPER::init_state();

    $state->{workdir} //= $self->{+WORKDIR};

    my $settings = $state->{settings} //= $self->{+SETTINGS} //= Test2::Harness::Settings->new(File::Spec->catfile($self->{+WORKDIR}, 'settings.json'));
    $state->{job_count} //= $self->{+JOB_COUNT} //= $settings->check_prefix('runner') ? $settings->runner->job_count // 1 : 1;

    for my $type (qw/resource plugin renderer/) {
        my $plural = "${type}s";
        my $raw;

        if ($type eq 'resource') {
            next unless $settings->check_prefix('runner');
            $raw  = $settings->runner->$plural // [];
            @$raw = sort { $a->sort_weight <=> $b->sort_weight } @$raw;
        }
        else {
            next unless $settings->check_prefix('harness');
            $raw = $settings->harness->$plural // [];
        }

        my $init_meth = "_init_${plural}";
        my ($list, $inst) = $self->$init_meth($settings, $raw);

        $state->{$plural}       = $list;
        $self->{"${type}_list"} = $list;
        $self->{$plural}        = $inst;
    }

    $state->{ipc_model} //= {};

    return $state;
}

sub settings {
    my $self = shift;
    return $self->{+SETTINGS} //= $self->transaction(r => sub { Test2::Harness::Settings->new(%{$_[0]->settings}) });
}

sub job_count {
    my $self = shift;
    return $self->{+JOB_COUNT} //= $self->transaction(r => sub { $_[0]->job_count });
}

sub _init_resources {
    my $self = shift;
    my ($settings, $list) = @_;

    my (@store, @inst);

    my $has_limiter = undef;

    for my $res (@$list) {
        require(mod2file($res));
        my $inst = $res->new(settings => $settings, observe => $self->{+OBSERVE});

        push @inst => $inst;
        push @store => $res;

        $has_limiter ||= $inst->job_limiter;
    }

    unless ($has_limiter) {
        require Test2::Harness::Runner::Resource::JobCount;
        push @store => 'Test2::Harness::Runner::Resource::JobCount';
        push @inst  => Test2::Harness::Runner::Resource::JobCount->new(settings => $settings, observe => $self->{+OBSERVE});
    }

    return (\@store, \@inst);
}

sub resource_list {
    my $self = shift;
    return $self->{+RESOURCE_LIST} // $self->transaction(r => sub {
        my ($state) = @_;
        my $settings = $self->settings;
        my ($list, $inst) = $self->_init_resources($settings, $state->resources);

        $self->{+RESOURCE_LIST} = $list;
        $self->{+RESOURCES}     = $inst;

        return $list;
    });
}

sub resources {
    my $self = shift;
    return $self->{+RESOURCES} // $self->transaction(r => sub {
        my ($state) = @_;
        my $settings = $self->settings;
        my ($list, $inst) = $self->_init_resources($settings, $state->resources);

        $self->{+RESOURCE_LIST} = $list;
        $self->{+RESOURCES}     = $inst;

        return $inst;
    });
}

sub _init_plugins {
    my $self = shift;
    my ($settings, $list) = @_;

    my (@store, @inst);

    for my $p (@$list) {
        require(mod2file($p));
        push @store => $p;

        next unless $p->can('new');

        my $inst = $p->new(settings => $settings);
        push @inst => $inst;
    }

    return (\@store, \@inst);
}

sub plugin_list {
    my $self = shift;
    my (@methods) = @_;

    my $plugins = $self->{+PLUGIN_LIST} // $self->transaction(r => sub {
        my ($state) = @_;
        my $settings = $self->settings;
        my ($list, $inst) = $self->_init_plugins($settings, $state->plugins);

        $self->{+PLUGIN_LIST} = $list;
        $self->{+PLUGINS}     = $inst;

        return $list;
    });

    return $plugins unless @methods;

    @methods = sort @methods;
    my $key = "MODS-" . join "|" => @methods;
    return $self->{+PLUGIN_LOOKUP}->{$key} //= [ grep { my $p = $_; my $out = 1; $out &&= $p->can($_) for @methods; $out } @$plugins ];
}

sub plugins {
    my $self = shift;
    my (@methods) = @_;

    my $plugins = $self->{+PLUGINS} // $self->transaction(r => sub {
        my ($state) = @_;
        my $settings = $self->settings;
        my ($list, $inst) = $self->_init_plugins($settings, $state->plugins);

        $self->{+PLUGIN_LIST} = $list;
        $self->{+PLUGINS}     = $inst;

        return $inst;
    });

    return $plugins unless @methods;

    @methods = sort @methods;
    my $key = "INST-" . join "|" => @methods;
    return $self->{+PLUGIN_LOOKUP}->{$key} //= [ grep { my $p = $_; my $out = 1; $out &&= $p->can($_) for @methods; $out } @$plugins ];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::State - State tracking for a yath instance

=head1 DESCRIPTION

This is the primary shared state for all processes participating in a yath
instance.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
