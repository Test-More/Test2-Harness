package App::Yath::Command::help;
use strict;
use warnings;

use Test2::Util qw/pkg_to_file/;

our $VERSION = '0.001027';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Test2::Harness::Util qw/open_file/;

sub show_bench { 0 }

sub summary { 'Show a this list of commands' }

sub group { '' }

sub run {
    my $self = shift;

    my $args = $self->{+ARGS};

    my @list;
    push @list => @{$args->{opts}} if $args;
    push @list => @{$args->{list}} if $args;

    return $self->command_help(shift @list) if @list;

    require Module::Pluggable;
    Module::Pluggable->import(search_path => ['App::Yath::Command']);

    my $len = 0;
    my %commands;
    for my $pkg ($self->plugins) {
        my $file = pkg_to_file($pkg);
        eval {
            require $file;

            unless($pkg->internal_only) {
                my $group = $pkg->group;
                my $name = $pkg->name;

                $commands{$group}->{$name} = $pkg->summary;
                my $l = length($name);
                $len = $l if $l > $len;
            }
            1;
        };
    }

    print "\nUsage: $0 COMMAND [options]\n\nAvailable Commands:\n";

    for my $group (sort keys %commands) {
        my $set = $commands{$group};

        printf("    %${len}s:  %s\n", $_, $set->{$_}) for sort keys %$set;
        print "\n";
    }

    return 0;
}

sub command_help {
    my $self = shift;
    my ($command) = @_;

    require App::Yath;
    my $cmd_class = App::Yath->load_command($command);
    print $cmd_class->new->usage;

    return 0;
}

sub generate_pod {

}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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
