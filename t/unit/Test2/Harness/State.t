use Test2::V0 -target => "Test2::Harness::State";

use ok $CLASS;

done_testing;

__END__


sub init {
    my $self = shift;

    my $workdir    = $self->{+WORKDIR};
    my $state_file = $self->{+STATE_FILE};

    if ($workdir) {
        $state_file //= $self->{+STATE_FILE} //= File::Spec->catfile($self->{+WORKDIR}, 'state.json');
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

    $self->SUPER::init();

    my @bad = grep { !$self->can(uc($_)) } keys %$self;
    croak "The following invalid keys were passed into the constructor: " . join(', ' => @bad)
        if @bad;

    $self->{+PLUGIN_LOOKUP} //= {};
}

sub init_state {
    my $self = shift;

    confess "Attempt to initialize state from an observer"
        if $self->{+OBSERVE};

    my $state = $self->SUPER::init_state();

    $state->{workdir} //= $self->{+WORKDIR};

    my $settings = $state->{settings} //= $self->{+SETTINGS} //= Test2::Harness::Settings->new(File::Spec->catfile($self->{+WORKDIR}, 'settings.json'));
    $state->{job_count} //= $self->{+JOB_COUNT} //= $settings->runner->job_count // 1;

    for my $type (qw/resource plugin/) {
        my $meth = "${type}s";
        my $raw  = $settings->runner->$meth // [];

        if ($type eq 'resource') {
            @$raw = sort { $a->sort_weight <=> $b->sort_weight } @$raw;
        }

        my $init_meth = "_init_${meth}";
        my ($list, $inst) = $self->$init_meth($settings, $raw);

        $state->{$meth}         = $list;
        $self->{"${type}_list"} = $list;
        $self->{$meth}          = $inst;
    }

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
