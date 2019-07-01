package Test2::Harness::Job::Runner;
use strict;
use warnings;

our $VERSION = '0.001078';

use Carp qw/croak confess/;
use List::Util qw/first/;
use Scalar::Util qw/openhandle/;
use Test2::Util qw/clone_io pkg_to_file/;

use File::Spec();

use Test2::Harness::Util qw/open_file fqmod/;

use Test2::Harness::Util::HashBase qw{
    -via
    -dir
    -job
};

sub init {
    my $self = shift;

    my $dir  = $self->{+DIR}  or croak "'dir' is a required attribute";
    my $job  = $self->{+JOB}  or croak "'job' is a required attribute";

    croak "Invalid output directory '$dir'" unless -d $dir;

    my $via = $self->{+VIA} ||= ['IPC'];
    croak "'via' must be an array reference"
        if !ref($via) || ref($via) ne 'ARRAY';
}

require Test2::Harness::Job::Runner::Open3;
require Test2::Harness::Job::Runner::IPC;
require Test2::Harness::Job::Runner::Fork;

my %RUN_MAP = (
    Open3 => 'Test2::Harness::Job::Runner::Open3',
    IPC   => 'Test2::Harness::Job::Runner::IPC',
    Fork  => 'Test2::Harness::Job::Runner::Fork',
);

sub run {
    my $self = shift;

    my $job = $self->{+JOB};

    my $via;

    for my $item (@{$self->{+VIA}}) {
        my $class = $RUN_MAP{$item};

        unless ($class) {
            $class = fqmod(__PACKAGE__, $item);
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
        my @out;

        return $class->run($self);
    }

    croak "No viable run method found";
}

sub output_filenames {
    my $self = shift;

    my $dir = $self->{+DIR};

    my $in_file   = File::Spec->catfile($dir, 'stdin');
    my $out_file  = File::Spec->catfile($dir, 'stdout');
    my $err_file  = File::Spec->catfile($dir, 'stderr');
    my $event_dir = File::Spec->catfile($dir, 'events');

    return ($in_file, $out_file, $err_file, $event_dir);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Runner - Logic to run a test job.

=head1 DESCRIPTION

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
