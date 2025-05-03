package App::Yath::IPC;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak confess/;
use File::Path qw/make_path/;
use Digest::SHA qw/sha1_hex/;
use Sys::Hostname qw/hostname/;

use Test2::Harness::Util qw/mod2file clean_path fqmod/;
use Test2::Harness::IPC::Util qw/pid_is_running/;
use Test2::Harness::IPC::Protocol;

use File::Spec();

use Test2::Harness::Util::HashBase qw{
    <settings
    <fixme

    +dir
    +ipcs
    +start
    +gen_ipc

    <connected
};

sub init {
    my $self = shift;

    croak "'settings' is a required attribute" unless $self->{+SETTINGS};
}

sub dir {
    my $self = shift;

    return $self->{+DIR} if $self->{+DIR};

    my $settings = $self->{+SETTINGS};

    my $ipc_dir = $settings->ipc->dir;
    return $self->{+DIR} = $ipc_dir if $ipc_dir;

    my $base = clean_path($settings->yath->base_dir);
    my $sha = sha1_hex($base);

    $ipc_dir = File::Spec->catdir($settings->yath->orig_tmp, "yath-ipc-$ENV{USER}-$sha");

    make_path($ipc_dir) unless -e $ipc_dir;

    return $self->{+DIR} = $ipc_dir;
}

sub ipcs {
    my $self = shift;
    return $self->{+IPCS} if $self->{+IPCS};

    if (my $file = $self->settings->ipc->file) {
        return $self->{+IPCS} = {
            user => [{
                type => 'user',
                $self->parse_ipc_file($file),
                file => $file,
            }]
        };
    }

    return $self->{+IPCS} = $self->_find_ipcs;
}

sub _find_ipcs {
    my $self = shift;

    my $settings = $self->settings;
    my $dir      = $self->dir;

    my $pre = $settings->ipc->prefix;

    my %found;

    my $regex = $self->parse_ipc_regex();

    opendir(my $dh, $dir) or die "Could not open dir '$dir'";
    for my $file (readdir($dh)) {
        next unless $file =~ $regex;
        my $full = File::Spec->catfile($dir, $file);
        my %ipc  = $self->parse_ipc_file($full);

        if (my $err = $ipc{error}) {
            warn "Skipping '$full': $@";
            next;
        }

        # This will be empty if the file could not be parsed
        my $type = $ipc{type} or next;

        if (my $pid = $ipc{peer_pid}) {
            unless (pid_is_running($pid)) {
                print "Detected stale runner file: $full\n Deleting...\n";
                unlink($full);
                next;
            }
        }

        push @{$found{$type}} => \%ipc;
    }
    closedir($dh);

    return \%found;
}

sub parse_ipc_regex {
    my $self = shift;
    my $pre  = $self->settings->ipc->prefix;

    #                      TYPE       PID   PROT     PORT
    return qr/^\Q$pre\E-(one|daemon)-(\d+)-(\w+)(?::(\d+))?$/;
}

sub parse_ipc_file {
    my $self = shift;
    my ($in) = @_;

    my $file = clean_path($in);
    my ($vol, $dir, $name) = File::Spec->splitpath($in);

    my %out = (file => $file);

    my $settings = $self->settings;
    my $ipc_s    = $settings->ipc;

    $out{peer_pid} //= $ipc_s->peer_pid;
    $out{protocol} //= $ipc_s->protocol;
    $out{port}     //= $ipc_s->port;

    my $regex = $self->parse_ipc_regex();

    if ($name =~ $regex) {
        my ($type, $pid, $prot, $port) = ($1, $2, $3, $4);

        $out{type}     //= $type;
        $out{peer_pid} //= $pid;
        $out{protocol} //= $prot;
        $out{port}     //= $port;
    }

    if (my $protocol = $out{protocol}) {
        if (eval { ($protocol) = $self->_load_protocol($protocol); 1 }) {
            $out{protocol} = $protocol;
            $out{address} //= $protocol->get_address($file);
        }
        else {
            $out{error} = $@;
        }
    }
    else {
        $out{error} = "No protocol";
    }

    return %out;
}

sub _load_protocol {
    my $self = shift;
    my ($in) = @_;

    my $prot   = fqmod($in, 'Test2::Harness::IPC::Protocol');
    my $pshort = $prot =~ m/^Test2::Harness::IPC::Protocol::(.+)$/ ? $1 : "+$prot";

    eval { require(mod2file($prot)); 1 } or die "\nFailed to load IPC protocol ($pshort): $@\n";

    return ($prot, $pshort);
}

sub start {
    my $self = shift;

    croak "Already started" if $self->{+START};

    my $specs = $self->_start(@_);
    $self->{+START} = $specs;

    my $ipc = Test2::Harness::IPC::Protocol->new(protocol => $specs->{protocol});
    $ipc->start($specs->{address}, $specs->{port});
    return $ipc;
}

sub validate_ipc {
    my $self = shift;
    my ($ipc) = @_;

    $ipc //= $self->_generate_ipc(daemon => 1);

    my $settings = $self->settings;

    if (my $ipc_file = $settings->ipc->file) {
        die "IPC file '$ipc_file' already exists!\n" if -e $ipc_file;
        return $ipc_file;
    }

    my @list = $self->find('daemon');
    if (@list && !$settings->ipc->allow_multiple) {
        die "\nExisting daemon runner(s) detected, and --ipc-allow-multiple was not specified:\n" . join("\n", map { "  PID $_->{peer_pid}: $_->{file}" } @list) . "\n\n";
    }

    die "Would create runner file '$ipc->{file}' but it already exists!\n"
        if $ipc && -e $ipc->{file};

    return $ipc;
}

sub _start {
    my $self = shift;
    my (%params) = @_;

    my $daemon = $params{daemon};
    my $settings = $self->{+SETTINGS};

    if (my $ipc_file = $settings->ipc->file) {
        die "IPC file '$ipc_file' already exists!\n" if -e $ipc_file;
        return {
            type => 'user',
            $self->parse_ipc_file($ipc_file),
            file => $ipc_file,
        };
    }

    my $ipc = $self->_generate_ipc(%params);
    $self->validate_ipc($ipc) if $daemon;

    my $dir = delete $ipc->{dir};
    unless (-d $dir) {
        make_path($dir) or die "Could not make path '$dir'";
    }

    return $ipc;
}

sub _generate_ipc {
    my $self = shift;
    my (%params) = @_;

    return $self->{+GEN_IPC} if $self->{+GEN_IPC};

    my $daemon = $params{daemon};

    my $settings = $self->{+SETTINGS};

    my $prot   = $settings->ipc->protocol // 'Test2::Harness::IPC::Protocol::AtomicPipe';
    my $pshort;
    ($prot, $pshort) = $self->_load_protocol($prot);

    my $port = $settings->ipc->port // $prot->default_port;
    $prot->verify_port($port);

    my $pre  = $settings->ipc->prefix;
    my $file = join "-" => ($pre, $daemon ? 'daemon' : 'one', $$, $pshort);
    $file .= ":${port}" if defined($port) && length($port);

    my $dir = $self->dir;
    my $full = clean_path(File::Spec->catfile($dir, $file));

    my $address = $settings->ipc->address // $prot->get_address($full);

    return $self->{+GEN_IPC} = {
        address   => $address,
        file      => $full,
        peer_pid  => $$,
        port      => $port,
        protocol  => $prot,
        type      => 'daemon',
        dir       => $dir,
    };
}

sub connect {
    my $self = shift;
    my (@types) = @_;

    my ($specs, @other) = $self->find(@types);

    die "Could not find a running yath daemon.\n" unless $specs;

    $self->die_with_selections($specs, @other)
        if @other;

    $self->{+CONNECTED} = $specs;

    my $ipc = Test2::Harness::IPC::Protocol->new(protocol => $specs->{protocol});
    my $con = $ipc->connect($specs->{address}, $specs->{port}, peer_pid => $specs->{peer_pid});

    return ($ipc, $con);
}

sub find {
    my $self = shift;
    my (@types) = @_;

    my $settings = $self->settings;

    unless (@types) {
        # user only returns anything if --ipc-file is specified
        @types = qw/user daemon/;
        push @types => 'one' if $settings->ipc->check_option('allow_non_daemon') && $settings->ipc->allow_non_daemon;
    }

    my $ipcs = $self->ipcs;

    return map { @{$ipcs->{$_} // []} } @types;
}

sub die_with_selections {
    my $self = shift;
    my (@ipcs) = @_;

    my $out = "Multiple runners detected, please select one using one of the following options:\n";
    $out .= "  --ipc-file '$_->{file}'\n" for @ipcs;
    $out .= "\n\n";

    die $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::IPC - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

