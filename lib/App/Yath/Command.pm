package App::Yath::Command;
use strict;
use warnings;

our $VERSION = '1.000155';

use File::Spec;
use Carp qw/croak/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Util::HashBase qw/-settings -args/;

use App::Yath::Options();

use Test2::Harness::Util::File::JSON();

sub internal_only   { 0 }
sub always_keep_dir { 0 }
sub summary         { "No Summary" }
sub description     { "No Description" }
sub group           { "Z-UNFINISHED" }
sub doc_args        { () }
sub only_cmd_opts   { 0 }

sub handle_invalid_option { 0 }

sub munge_opts { }

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
    my $script   = $settings->harness->script // $0;

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options = $params{options};
    unless ($options) {
        $options = App::Yath::Options->new;
        $options->set_command_class($class);
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
    my $pre_opts = $options->pre_docs('pod', 3);
    my $cmd_opts = $options->cmd_docs('pod', 3);

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

sub setup_resources {
    my $self = shift;
    my $settings = $self->settings;

    return unless $settings->check_prefix('runner');
    my $runner = $settings->runner;
    my $res = $runner->resources or return;
    return unless @$res;

    for my $res (@$res) {
        require(mod2file($res)) unless ref $res;
        $res->setup($settings);
    }
}

sub setup_plugins {
    my $self = shift;
    $_->setup($self->settings) for @{$self->settings->harness->plugins};
}

sub teardown_plugins {
    my $self = shift;
    my ($renderers, $logger) = @_;
    $_->teardown($self->settings, $renderers, $logger) for @{$self->settings->harness->plugins};
}

sub finalize_plugins {
    my $self = shift;
    $_->finalize($self->settings) for @{$self->settings->harness->plugins};
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command - Base class for yath commands

=head1 DESCRIPTION

This is the base class for any/all yath commands. If you wish to add a new yath
command you should subclass this package.

=head1 SYNOPSIS

    package App::Yath::Command::mycommand;
    use strict;
    use warnings;

    use App::Yath::Options();
    use parent 'App::Yath::Command';

    # Include existing option sets
    include_options(
        'App::Yath::Options::Debug',
        'App::Yath::Options::PreCommand',
        ...,
    );

    # Add some custom options
    option_group {prefix => 'mycommand', category => 'mycommand options'} => sub {
        option foo => (
            description => "the foo option",
            default     => 0,
        );
    };

    # This is used to sort/group commands in the "yath help" output
    sub group { 'thirdparty' }

    # Brief 1-line summary
    sub summary { "This is a third party command, it does stuff..." }

    # Longer description of the command (used in yath help mycommand)
    sub description {
        return <<"    EOT";
    This command does:
    This
    That
    Those
        EOT
    }

    # Entrypoint
    sub run {
        my $self = shift;

        my $settings = $self->settings;
        my $args     = $self->args;

        print "Hello Third Party!\n"

        # Return an exit value.
        return 0;
    }

=head1 CLASS METHODS

=over 4

=item $string = $cmd_class->cli_help(settings => $settings, options => $options)

This method generates the command line help for any given command. In general
you will NOT want to override this.

$settings should be an instance of L<Test2::Harness::Settings>.

$options should be an instance of L<App::Yath::Options> if provided. This
method is usually capable of filling in the details when this is omitted.

=item $multi_line_string = $cmd_class->description()

Long-form description of the command. Used in C<cli_help()>.

=item @list = $cmd_class->doc_args()

A list of argument names to the command, used to generate documentation.

=item $string = $cmd_class->generate_pod()

This can be used to generate POD documentation from the command itself using
the other fields listed in this section, as well as all applicable command
lines options specified in the command.

=item $string = $cmd_class->group()

Used for sorting/grouping commands in the C<yath help> output.

Existing groups:

    ' test'     # Space in front to make sure test related command float up
    'log'       # Log processing commands
    'persist'   # Commands related to the persistent runner
    'zinit'     # The init command and related command sink to the bottom.

Unless your command OBVIOUSLY and CLEARLY belongs in one of the above groups
you should probably create your own. Please do not prefix it with a space to
make it float, C<' test'> is a special case, you are not that special.

=item $string = $cmd_class->name()

Name of the command. By default this is the last part of the package name. You
will probably never want to override this.

=item $short_string = $cmd_class->summary()

A short summary of what this command is.

=back

=head1 OBJECT METHODS

=over 4

=item $bool = $cmd->always_keep_dir()

By default the working directory is deleted when yath exits. Some commands such
as L<App::Yath::Command::start> need to keep the directory. Override this
method to return true if your command uses the workdir and needs to keep it.

=item $arrayref = $cmd->args()

Get an arrayref of command line arguments B<AFTER> options have been
process/removed.

=item $bool = $cmd->internal_only()

Set this to true if you do not want your command to show up in the help output.

=item $exit_code = $cmd->run()

This is the main entrypoint for the command. You B<MUST> override this. This
method should return an exit code.

=item $settings = $cmd->settings()

Get the settings as populated by the command line options.

=item $cmd->write_settings_to($directory, $filename)

A helper method to write the settings to a specified directory and filename.
File is written as JSON.

If you are subclassing another command such as L<App::Yath::Command::test> you
may want to override this to a no-op to prevent the settings file from being
written, the L<App::Yath::Command:run> command does this.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
