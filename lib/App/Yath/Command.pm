package App::Yath::Command;
use strict;
use warnings;

use v5.10;

our $VERSION = '1.000000';

use File::Spec;
use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw/-settings -args/;

use App::Yath::Options();

use Test2::Harness::Util::File::JSON();

sub internal_only   { 0 }
sub always_keep_dir { 0 }
sub summary         { "No Summary" }
sub description     { "No Description" }
sub group           { "Z-UNFINISHED" }
sub doc_args        { () }

sub name { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }

sub run {
    my $self = shift;

    warn "This command is currently empty";

    return 1;
}

sub cli_help {
    my $class = shift;
    my %params = @_;

    my $settings = $params{settings} // {};
    my $script   = $settings->yath->script // $0;

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options = $params{options};
    unless ($options) {
        $options = App::Yath::Options->new;
        $options->set_command_class($class);
    }

    if ( $options && $options->command_class && -t STDIN ) {
        my $command_class = $options->command_class;
        local $ENV{PERL5LIB};
        my $perldoc = qq[$^Xdoc];
        $perldoc = q[perldoc] unless -x $perldoc;

        exec( $perldoc, $command_class );
        die "Failed to run perldoc: $!";
    }

    my ($pre_opts, $cmd_opts);
    if ($options) {
        $pre_opts = $options->pre_docs('cli');
        $cmd_opts = $options->cmd_docs('cli');
    }

    my $usage = "Usage: $script";

    my @out;

    if ($pre_opts) {
        $usage .= ' [YATH OPTIONS]';

        $pre_opts =~ s/^/  /mg;
        push @out => "[YATH OPTIONS]\n$pre_opts";
    }

    $usage .= " $cmd";

    if ($cmd_opts) {
        $usage .= " [COMMAND OPTIONS]";

        $cmd_opts =~ s/^/  /mg;
        push @out => "[COMMAND OPTIONS]\n$cmd_opts";
    }

    if (@args) {
        $usage .= " [COMMAND ARGUMENTS]";

        my @desc;
        for my $arg (@args) {
            if (ref($arg)) {
                my ($name, $text) = @$arg;
                push @desc => $name;
                $text =~ s/^/  /mg;
                push @desc => "$text\n";
            }
            else {
                push @desc => "$arg\n";
            }
        }

        my $desc = join "\n" => @desc;
        $desc =~ s/^/  /mg;

        push @out => "[COMMAND ARGUMENTS]\n$desc";
    }

    chomp(my $desc = $class->description);
    unshift @out => ("$cmd - " . $class->summary, $desc, $usage);

    return join("\n\n" => grep { $_ } @out) . "\n";
}

sub generate_pod {
    my $class = shift;

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options = App::Yath::Options->new();
    require App::Yath;
    my $ay = App::Yath->new();
    $options->include($ay->load_options);
    $options->set_command_class($class);
    my $pre_opts = $options->pre_docs('pod');
    my $cmd_opts = $options->cmd_docs('pod');

    my $usage = "    \$ yath [YATH OPTIONS] $cmd";

    my @head2s;

    push @head2s => ("=head2 YATH OPTIONS",    $pre_opts) if $pre_opts;

    if ($cmd_opts) {
        $usage .= " [COMMAND OPTIONS]";
        push @head2s => ("=head2 COMMAND OPTIONS", $cmd_opts);
    }

    if (@args) {
        $usage .= " [COMMAND ARGUMENTS]";

        push @head2s => (
            "=head2 COMMAND ARGUMENTS",
            "=over 4",
            (map { ref($_) ? ( "=item $_->[0]", $_->[1] ) : ("=item $_") } @args),
            "=back"
        );
    }

    my @out = (
        "=head1 NAME",
        "$class - " . $class->summary,
        "=head1 DESCRIPTION",
        $class->description,
        "=head1 USAGE",
        $usage,
        @head2s
    );

    return join("\n\n" => grep { $_ } @out);
}

sub write_settings_to {
    my $self = shift;
    my ($dir, $file) = @_;

    croak "'directory' is a required parameter" unless $dir;
    croak "'filename' is a required parameter" unless $file;

    my $settings = $self->settings;
    my $settings_file = Test2::Harness::Util::File::JSON->new(name => File::Spec->catfile($dir, $file));
    $settings_file->write($settings);
    return $settings_file->name;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command - Base class for yath commands

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
