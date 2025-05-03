package Test2::Harness::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use Config qw/%Config/;
use Scalar::Util qw/blessed/;

use Test2::Harness::TestFile;

use Test2::Harness::Util qw/clean_path/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    <test_file
    <job_id
    <results
    running
    <args
};

sub init {
    my $self = shift;

    $self->{+RUNNING} = 0;

    $self->{+JOB_ID} //= gen_uuid();

    my $tf = $self->{+TEST_FILE} or croak "'test_file' is a required field";

    $self->{+RESULTS} //= [];

    $self->{+ARGS} //= [];

    $self->{+TEST_FILE} = Test2::Harness::TestFile->new($tf)
        unless blessed($tf);
}

sub try {
    my $self = shift;
    return scalar(@{$self->{+RESULTS}});
}

sub resource_id {
    my $self = shift;
    my $job_id = $self->{+JOB_ID};
    my $try = $self->try // 0;
    return "${job_id}:${try}";
}

sub launch_command {
    my $self = shift;
    my ($run, $ts) = @_;

    my $run_file = $self->test_file->relative;

    if (my $ch_dir = $ts->ch_dir) {
        $run_file = $self->test_file->file;
        $run_file =~ s{^$ch_dir/?}{}g;
    }

    my @includes = map { $_ eq '.' ? $_ : clean_path($_) } @{$ts->includes};

    if ($self->test_file->non_perl) {
        $run_file = "./$run_file" unless $run_file =~ m{^[/\.]};
        return ([$run_file, @{$ts->args // []}], {PERL5LIB => join($Config{path_sep} => @includes, $ENV{PERL5LIB})});
    }

    @includes = map { "-I$_" } @includes;
    my @loads = map { "-m$_" } @{$ts->load};

    my $load_import = $ts->load_import;
    my @imports;
    for my $mod (@{$load_import->{'@'} // []}) {
        my $args = $load_import->{$mod} // [];

        if ($args && @$args) {
            push @imports => "-M$mod=" . join(',' => @$args);
        }
        else {
            push @imports => "-M$mod";
        }
    }

    return [
        $^X,
        @{$ts->switches // []},
        @includes,
        @imports,
        @loads,
        $run_file,
        @{$self->args // []},
        @{$ts->args   // []},
    ];
}

sub TO_JSON {
    my $self = shift;
    my $class = blessed($self);

    return {
        %$self,
        job_class => $class,
    };
}

sub process_info {
    my $self = shift;

    my $out = $self->TO_JSON;

    delete $out->{+TEST_FILE};
    delete $out->{+RESULTS};

    delete $out->{$_} for grep { m/^_/ } keys %$out;

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run::Job - FIXME

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

