package Test2::Harness2::Reloader::Moose;
use strict;
use warnings;

our $VERSION = '2.000011';

use constant HAVE_MOOSE       => eval { require Moose;                  1 };
use constant HAVE_MOOSE_UTIL  => eval { require Moose::Util;            1 };
use constant HAVE_CLASS_MOP   => eval { require Class::MOP;             1 };
use constant HAVE_META_MOP    => eval { require Class::MOP::Class;      1 };

sub viable {
    return HAVE_MOOSE && HAVE_CLASS_MOP && HAVE_META_MOP;
}

sub reload {
    my $class = shift;
    my ($file, $info) = @_;

    return (0, reason => "Reloader::Moose: Moose/Class::MOP not available")
        unless $class->viable;

    my $mod = $info->{module}
        or return (0, reason => "Reloader::Moose requires a module name in file_info");

    my $is_role = 0;
    {
        my $meta = $mod->can('meta') ? eval { $mod->meta } : undef;
        $is_role = 1 if $meta && $meta->isa('Moose::Meta::Role');
    }

    # 1. Remove the current metaclass so the new definition re-registers a
    #    fresh one when it runs. Class::MOP keeps a registry keyed by
    #    package name; without this the second load typically no-ops on
    #    accessor/method changes.
    {
        my $ok = eval { Class::MOP::remove_metaclass_by_name($mod); 1 };
        return (0, reason => "Reloader::Moose: failed to remove metaclass for $mod: $@")
            unless $ok;
    }

    # 2. Wipe the stash so method/attribute definitions are gone.
    {
        no strict 'refs';
        my $stash = \%{"${mod}\::"};
        for my $sym (keys %$stash) {
            next if $sym =~ m/::$/;
            delete $stash->{$sym};
        }
    }

    # 3. Drop %INC entries so require actually re-runs the file.
    delete $INC{$info->{inc_entry}} if $info->{inc_entry};
    delete $INC{$file};

    # 4. Re-run the file. Moose/Moose::Role's own metaclass setup runs
    #    again, re-registering everything.
    {
        local $.;
        my $ok = eval { require $file; 1 };
        return (0, reason => "Reloader::Moose: require failed for $file: $@")
            unless $ok;
    }

    $INC{$file}             //= $file;
    $INC{$info->{inc_entry}} //= $file if $info->{inc_entry};

    # 5. For role files, re-apply the role to every class that consumed it,
    #    so their method lists pick up any changes. We get the consumer
    #    list from the fresh metaclass (Moose tracks this automatically).
    if ($is_role && $mod->can('meta')) {
        my $meta = eval { $mod->meta };
        if ($meta && $meta->isa('Moose::Meta::Role')) {
            # Consumers are tracked on the meta object under a number of
            # slightly-different keys depending on Moose version. Use the
            # documented accessor when available.
            my @consumers;
            if ($meta->can('consumers')) {
                @consumers = $meta->consumers;
            }
            for my $consumer (@consumers) {
                my $cmeta = $consumer->can('meta') ? eval { $consumer->meta } : undef;
                next unless $cmeta;
                eval { Moose::Util::apply_all_roles($consumer, $mod); 1 };
            }
        }
    }

    return (1);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Moose - Metaclass-aware reload helper for Moose
classes and roles.

=head1 DESCRIPTION

The generic "clear the stash and re-require" reload strategy does not work
well for Moose. Moose caches state on the class metaclass object that
C<Class::MOP> keeps in its own registry; simply re-running the class
definition does not replace that registry entry, so accessor and method
modifier changes often fail to take effect.

This helper:

=over 4

=item 1. Removes the metaclass from the C<Class::MOP> registry.

=item 2. Clears the package stash.

=item 3. Deletes the relevant C<%INC> entries and re-C<require>s the file.

=item 4. For role files, re-applies the role to every consumer via
L<Moose::Util/apply_all_roles>.

=back

It is consulted automatically by L<Test2::Harness2::Reloader> when the file
under reload appears to define a Moose class or role and when this helper
reports C<viable> true.

=head1 METHODS

=over 4

=item $bool = Test2::Harness2::Reloader::Moose->viable

True only when Moose and Class::MOP are installed.

=item ($status, %fields) = Test2::Harness2::Reloader::Moose->reload($file, $info)

Reload C<$file>. Returns C<(1)> on success, C<(0, reason =E<gt> $msg)> on
failure.

=back

=head1 CAVEATS

=over 4

=item Live instances

Previously-constructed instances keep their blessed-into-class identity,
which means they see the new methods (method dispatch happens via the
stash), but attribute metaclass changes may not be reflected for them.
Tests that construct objects before a reload and then assert on their
behavior after the reload should re-construct to be safe.

=item MooseX extensions

Most C<MooseX::*> extensions work by installing or altering the metaclass.
Where the extension participates through standard Moose hooks (meta-role
application at class-creation time), reload is clean. Where the extension
mutates the metaclass imperatively after construction, a reload may miss
those mutations.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
