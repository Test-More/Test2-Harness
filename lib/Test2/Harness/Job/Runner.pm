package Test2::Harness::Job::Runner;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak confess/;
use List::Util qw/first/;
use IPC::Open3 qw/open3/;
use Scalar::Util qw/openhandle/;
use Test2::Util qw/clone_io pkg_to_file/;

use File::Spec();

use Test2::Harness::Util qw/open_file/;

use Test2::Harness::Util::HashBase qw{
    -via
    -dir

    -job
    -file

    -_scanned -_headers -_shbang
};

sub init {
    my $self = shift;

    my $dir  = $self->{+DIR}  or croak "'dir' is a required attribute";
    my $job  = $self->{+JOB}  or croak "'job' is a required attribute";

    my $file = $job->file;

    # We want absolute path
    $file = File::Spec->rel2abs($file);
    $self->{+FILE} = $file;

    croak "Invalid output directory '$dir'" unless -d $dir;
    croak "Invalid test file '$file'"       unless -f $file;

    my $via = $self->{+VIA} ||= ['Open3'];
    croak "'via' must be an array reference"
        if !ref($via) || ref($via) ne 'ARRAY';
}

require Test2::Harness::Job::Runner::Open3;
require Test2::Harness::Job::Runner::Fork;

my %RUN_MAP = (
    Open3 => 'Test2::Harness::Job::Runner::Open3',
    Fork  => 'Test2::Harness::Job::Runner::Fork',
);

sub run {
    my $self = shift;

    my $via;

    for my $item (@{$self->{+VIA}}) {
        next if $item eq 'Fork' && $self->job->no_fork;
        my $class = $RUN_MAP{$item};

        unless ($class) {
            if ($item =~ m/^\+(.*)/) {
                $class = $1;
            }
            else {
                $class = __PACKAGE__ . "::$item";
            }

            my $file = pkg_to_file($class);
            my $ok   = eval { require $file; 1 };
            my $err  = $@;
            unless ($ok) {
                next if $err =~ m/Can't locate \Q$file\E in \@INC/;
                die $@;
            }

            $RUN_MAP{$item} = $class;
        }

        next unless $class->viable($self);
        return $class->run($self);
    }

    croak "No viable run method found";
}

sub output_filenames {
    my $self = shift;

    my $dir = $self->{+DIR};

    my $in_file    = File::Spec->catfile($dir, 'stdin');
    my $out_file   = File::Spec->catfile($dir, 'stdout');
    my $err_file   = File::Spec->catfile($dir, 'stderr');
    my $event_file = File::Spec->catfile($dir, 'events.jsonl');

    return ($in_file, $out_file, $err_file, $event_file);
}

sub no_stream { shift->job->no_stream }
sub env_vars  { shift->job->env_vars }
sub libs      { shift->job->libs }
sub args      { shift->job->args }
sub input     { shift->job->input }

sub headers {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_HEADERS};
    return {%{$self->{+_HEADERS}}};
}

sub shbang {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_SHBANG};
    return {%{$self->{+_SHBANG}}};
}

sub switches {
    my $self = shift;

    my @out;

    push @out => @{$self->job->switches};

    if (my $shbang = $self->shbang) {
        if (my $switches = $shbang->{switches}) {
            push @out => @$switches;
        }
    }

    return \@out;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;

    open(my $fh, '<', $self->{+FILE}) or die "Could not open file '$self->{+FILE}': $!";

    my %headers;
    for (my $ln = 0; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 0) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang) {
                $self->{+_SHBANG} = $shbang;
                next;
            }
        }

        next if $line =~ m/^(use|require|BEGIN)/;
        last unless $line =~ m/^\s*#/;

        next unless $line =~ m/^\s*#\s*HARNESS-(.+)$/;

        my ($dir, @args) = split /-/, lc($1);
        if ($dir eq 'no') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 0;
        }
        elsif ($dir eq 'yes') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 1;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    $self->{+_HEADERS} = \%headers;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    # NOTE: Test this, the dashes should be included with the switches
    my $shbang_re = qr{
        ^
          \#!.*\bperl.*?        # the perl path
          (?: \s (-.+) )?       # the switches, maybe
          \s*
        $
    }xi;

    if ($line =~ $shbang_re) {
        my @switches = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }

    return \%shbang;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Runner - Logic to run a test job.

=head1 DESCRIPTION

=back

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
