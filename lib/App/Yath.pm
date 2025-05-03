package App::Yath;
use strict;
use warnings;

use feature 'state';

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    <config
    <settings
    +options

    <argv
    <orig_argv
    <env_vars
    <option_state

    <command
    +color


    <state_env
    <state_cleared
    <state_modules
};

use Getopt::Yath();
use Getopt::Yath::Settings;
use Getopt::Yath::Term qw/USE_COLOR color fit_to_width/;

use App::Yath::Options::Yath;
use App::Yath::ConfigFile;
use App::Yath::Util qw/paged_print/;

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;
use File::Path qw/remove_tree/;
use File::Spec;
use Term::Table;

use Test2::Util::Table qw/table/;
use Test2::Harness::Util qw/find_libraries clean_path mod2file read_file/;
use Test2::Harness::Util::JSON qw/encode_pretty_json decode_json/;

my $APP_PATH = __FILE__;
$APP_PATH =~ s{App\S+Yath\.pm$}{}g;
$APP_PATH = clean_path($APP_PATH);
sub app_path { $APP_PATH }

sub use_color {
    my $self = shift;
    return $self->{+COLOR} if defined $self->{+COLOR};
    return $self->{+COLOR} = 0 unless USE_COLOR;

    if ($self->{+SETTINGS}->check_group('term')) {
        return $self->{+COLOR} = $self->{+SETTINGS}->term->color ? 1 : 0;
    }

    return $self->{+COLOR} = -t STDOUT ? 1 : 0;
}

sub init {
    my $self = shift;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $self->{argv}      //= [];
    $self->{+ENV_VARS} //= {};
    $self->{+CONFIG}   //= {};
    $self->{+SETTINGS} //= Getopt::Yath::Settings->new;
    $self->{+ORIG_ARGV} = [@{$self->argv}];
}

sub cli_help {
    my $self = shift;
    my ($options, %params) = @_;

    my $settings = $self->{+SETTINGS};
    my $cmd_class = $self->command;

    $options //= $self->options;

    my $help = "";

    my $no_cmd = 0;
    my $cmd = "COMMAND";
    if ($cmd_class) {
        $cmd = $cmd_class->name // 'COMMAND';
        if ($self->use_color) {
            $help .= "\n";
            $help .= color('bold white') . "Command selected: ";
            $help .= color('reset');
            $help .= color('bold green') . $cmd;
            $help .= color('reset');
            $help .= color('yellow') . " ($cmd_class)\n\n";
            $help .= color('reset');
        }
        else {
            $help .= "\nCommand selected: $cmd ($cmd_class)\n";
        }
    }
    else {
        $no_cmd = 1;
        require App::Yath::Command::help;
        $cmd_class //= 'App::Yath::Command::help';
    }

    my @desc = map { fit_to_width(" ", $_) } split /\n\n/, $cmd_class->description;
    $help .= join "\n\n" => @desc;

    my $opts = $options->docs('cli', groups => {':{' => '}:'}, group => $params{group}, settings => $settings, color => $self->use_color);

    my $script = File::Spec->abs2rel($settings->yath->script // $0);

    my $colors = {reset => ''};
    if ($self->use_color) {
        $colors = {
            reset     => color('reset'),
            usage     => color('bold white'),
            script    => color('white'),
            yath_opts => color('cyan'),
            command   => color('bold green'),
            cmd_opts  => color('cyan'),
            '--a'     => color('yellow'),
            '--b'     => color('yellow'),
            arguments => color('white'),
            tests     => color('green'),
            dot_args  => color('magenta'),
        };
    }

    my $parts = {
        usage     => "USAGE:",
        script    => $script,
        yath_opts => "[YATH OPTIONS]",
        command   => $cmd,
        cmd_opts  => "[OPTIONS FOR COMMAND AND/OR YATH]",
        ($cmd_class->cli_args || $cmd_class->args_include_tests) ? ('--a'     => "[[--]", '--b' => ']')                      : (),
        $cmd_class->args_include_tests                           ? (tests     => "[TEST :{ ARGS TO PASS TO TEST }:]")        : (),
        $cmd_class->cli_args                                     ? (arguments => $cmd_class->cli_args)                       : (),
        $cmd_class->accepts_dot_args                             ? (dot_args  => $cmd_class->cli_dot || "[:: PASS-THROUGH]") : (),
    };

    my $usage = join " " => map { ($colors->{$_} || '') . $parts->{$_} . $colors->{reset} } grep { $parts->{$_} } qw/usage script yath_opts command cmd_opts --a tests arguments/;
    $usage .= ($colors->{'--b'} || '') . $parts->{'--b'} . $colors->{'reset'} if $parts->{'--b'};
    $usage .= " " . ($colors->{'dot_args'} || '') . $parts->{'dot_args'} . $colors->{'reset'} if $parts->{'dot_args'};

    my $end = "";
    if ($settings->yath->help && !$params{group}) {
        $end = $self->_render_groups(
            title => 'If the above help output is too much, you can limit it to specific option groups',
            param => '--help=GROUP_NAME',
        );
    }

    my $cmds = "";
    if ($no_cmd) {
        $settings->create_group('help');
        $settings->help->create_option(verbose => 0);
        my $it = App::Yath::Command::help->new(settings => $settings);
        $cmds = $it->command_table;
    }

    return "${usage}\n${help}\n${opts}\n${end}\n${cmds}";
}

sub _strip_color {
    my $self = shift;
    my ($colors, $line) = @_;
    return $line unless $self->use_color;

    my $pattern = join '|' => map { "\Q$_\E"} grep { $_ } values %$colors;
    $line =~ s/($pattern)//g if $pattern;

    return $line;
}

sub _render_groups {
    my $self = shift;
    my %params = @_;

    my $title = $params{title};
    my $param = $params{param};

    my $settings = $self->settings;
    my $script = File::Spec->abs2rel($settings->yath->script // $0);

    my %color;
    if ($self->use_color) {
        $color{$_}    = color("bold $_") for qw/red green yellow/;
        $color{bold}  = color('bold white');
        $color{reset} = color('reset');
    }
    else {
        $color{$_} = '' for qw/bold red green yellow reset/;
    }

    my %seen;
    my $options = $self->options;
    my $groups = [grep { !$seen{$_->[0]}++ } map { [$_->group, $_->category] } sort { $options->doc_sort_ops($a, $b, group_first => 1) } @{$options->options}];
    my ($h1, $h2, $h3, @g) = Term::Table->new(rows => $groups, header => ["Group Name", "Description"])->render;

    if ($self->use_color) {
        $h2 =~ s/([^\s\|]+)/$color{bold}$1$color{reset}/g;
        s/^\| ([^\|]+)/| $color{green}$1$color{reset}/ for @g;
    }

    my $tline = "$color{red}***$color{reset} $color{bold}${title}$color{reset} $color{red}***$color{reset}";
    my $tstrip = $self->_strip_color(\%color, $tline);
    my $border = $color{red} . ('*' x length($tstrip)) . $color{reset};
    my $line   = "$color{red}*$color{reset}" . (' ' x (length($tstrip) - 2)) . "$color{red}*$color{reset}";

    my @inside = (
        "$script [...] $color{green}${param}$color{reset}",
        "",
        "$color{yellow}The following groups can be selected:$color{reset}",
        ($h1, $h2, $h3, @g),
    );

    for my $i (@inside) {
        my $stripped = $self->_strip_color(\%color, $i);
        my $new = $line;
        substr($new, length("$color{red}*$color{reset}    "), length($stripped), $i);
        $i = $new;
    }

    my $inside = join "\n" => @inside;

    return <<"    EOT";
${border}
${tline}
${border}
${line}
${inside}
${line}
${border}

    EOT
}

sub options {
    my $self = shift;

    return $self->{+OPTIONS} if $self->{+OPTIONS};

    $self->{+OPTIONS} = Getopt::Yath::Instance->new(
        category_sort_map => {
            'NO CATEGORY - FIX ME' => 99999,
            'Yath Options'         => -100,
            'Command Options'      => -90,
            'Harness Options'      => -80,
        },
    );
    $self->{+OPTIONS}->include(App::Yath::Options::Yath->options);

    return $self->{+OPTIONS};
}

sub _groups_and_stops {
    my $self = shift;

    return (
        stops    => ['--', '::'],
        groups   => {':{' => '}:'},
    );
}

sub _default_process_arg_fields {
    my $self = shift;

    return (
        env      => $self->{+STATE_ENV}     //= {},
        cleared  => $self->{+STATE_CLEARED} //= {},
        modules  => $self->{+STATE_MODULES} //= {},
        settings => $self->{+SETTINGS},
        $self->_groups_and_stops,
    );
}

sub _process_global_args {
    my $self = shift;
    my ($args, %params) = @_;

    return $self->_process_args(
        $args,
        %params,

        skip_posts => 1,
        stop_at_non_opts => 1,

        invalid_opt_callback => sub {
            my ($opt) = @_;
            print STDERR "\nERROR: '$opt' is not a valid yath option.\nSee `yath --help` for a list of available options.\n(Command specific options must come after the command, did you forget to specify a command?)\n\n";
            exit 255;
        },
    );
}

sub _process_command_args {
    my $self = shift;
    my ($args, %params) = @_;

    my $cmd = delete $params{cmd} or croak "'cmd' arg missing";

    return $self->_process_args(
        $args,
        %params,

        skip_non_opts => 1,

        invalid_opt_callback => sub {
            my ($opt) = @_;
            print STDERR "\nERROR: '$opt' is not a valid yath or '$cmd' command option.\nSee `yath $cmd --help` for available options.\n\n";
            exit 255;
        },
    );
}

sub _process_args {
    my $self = shift;
    my ($args, %params) = @_;

    return $self->options->process_args(
        $args,
        $self->_default_process_arg_fields,
        %params,
    );
}

sub check_command {
    my $self = shift;
    my ($cmd) = @_;

    state %check_cache;

    return @{$check_cache{$cmd}} if $check_cache{$cmd};

    $cmd =~ s/-/::/g;
    my $cmd_class = "App::Yath::Command::$cmd";
    my $cmd_file = mod2file($cmd_class);

    unless (eval { require $cmd_file; die "$cmd_class does not subclass App::Yath::Command.\n" unless $cmd_class->isa('App::Yath::Command'); 1 }) {
        return @{$check_cache{$cmd} = [0, $@]};
    }

    return @{$check_cache{$cmd} = [1, undef]};
}

sub load_command {
    my $self = shift;
    my ($cmd) = @_;

    $cmd =~ s/-/::/g;
    my $cmd_class = "App::Yath::Command::$cmd";
    my $cmd_file = mod2file($cmd_class);

    my ($ok, $err) = $self->check_command($cmd);
    unless ($ok) {
        my $eq80 = '=' x 80;
        print STDERR "\nERROR: '$cmd' ($cmd_class) does not look like a valid command:\n${eq80}\n$err${eq80}\n";
        exit 255;
    }

    my $settings = $self->{+SETTINGS};
    my $opts = $self->options;

    $opts->include($cmd_class->options) if $cmd_class->can('options');
    $settings->yath->create_option(command => $cmd_class);
    $self->{+COMMAND} = $cmd_class;

    $self->include_options('plugins'  => 'App::Yath::Plugin::*')   if $cmd_class->load_plugins();
    $self->include_options('resource' => 'App::Yath::Resource::*') if $cmd_class->load_resources();
    $self->include_options('renderer' => 'App::Yath::Renderer::*') if $cmd_class->load_renderers();

    return $cmd_class;
}

sub process_args {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $argv = $self->argv;

    my @configs;
    for my $attr (qw/config_file user_config_file/) {
        my $file = $settings->yath->$attr or next;

        my $config = App::Yath::ConfigFile->new(file => $file);
        push @configs => $config;
        unshift @$argv => $config->global;
    }

    my $state = $self->_process_global_args($argv);

    my ($cmd, $cmd_class);

    my $stop = $state->{stop};
    my $remains = $state->{remains} //= [];
    if ($stop || !@$remains) {
        my @cmd_args;

        my $is_do   = $stop       && $stop eq 'do';
        my $is_stop = (!$is_do)   && $stop    && ($stop eq '--' || $stop eq '::');
        my $is_cmd  = (!$is_stop) && $stop    && ($self->check_command($stop))[0];
        my $is_path = $stop       && -e $stop && !($is_do || $is_stop || $is_cmd);

        @cmd_args = @{$state->{skipped}};

        if ($is_do || $is_stop || $is_path || !$is_cmd) {
            print STDERR "\n** Note: You should use the `do`, `run` or `test` commands, relying on the default behavior when no command is specified is discouraged. **\n\n"
                unless $is_do;

            push @cmd_args => $stop if $stop && !$is_do && !$is_cmd;

            require App::Yath::Options::IPC;
            my $ipc_state = App::Yath::Options::IPC->options->process_args(
                [@cmd_args],
                $self->_groups_and_stops,
                skip_posts    => 1,
                skip_non_opts => 1,
            );

            require App::Yath::IPC;
            if (App::Yath::IPC->new(settings => $ipc_state->{settings})->find()) {
                print "Found a persistent runner, defaulting to the 'run' command.\n";
                $cmd = 'run';
            }
            else {
                print "No persistent runner, defaulting to the 'test' command.\n";
                $cmd = 'test';
            }
        }
        else {
            $cmd = $stop;
        }

        @cmd_args = (
            (map { $_->command($cmd) } reverse @configs),
            @cmd_args,
            @{$state->{remains} // []},
        );

        $cmd_class = $self->load_command($cmd) if $cmd;

        $state = $self->_process_command_args(\@cmd_args, cmd => $cmd);
    }

    $cmd //= 'do';
    $cmd_class //= 'App::Yath::Command::do';

    my $dot_args;
    $argv = [@{$state->{skipped}}];
    if (my $stop = $state->{stop}) {
        if ($stop eq '--') {
            for my $arg (@{$state->{remains}}) {
                if    ($dot_args)   { push @$dot_args => $arg }
                elsif ($arg eq '::') { $dot_args //= [] }
                else                 { push @$argv => $arg }
            }
        }
        elsif ($stop eq '::') {
            push @{$dot_args //= []} => @{$state->{remains}};
        }
        else {
            push @$argv => ($stop, @{$state->{remains}});
        }
    }
    else {
        push @$argv => @{$state->{remains}};
    }

    if ($dot_args) {
        die "'::' cannot be used with the '$cmd' command" unless $cmd_class->accepts_dot_args;
        $cmd_class->set_dot_args($settings, $dot_args);
    }

    $self->{argv} = $argv;

    $self->{+ENV_VARS} = $self->{+STATE_ENV};
    $self->{+OPTION_STATE} = $state;

    for my $module (keys %{$self->{+STATE_MODULES}}) {
        for my $set (['yath', 'plugins', 'App::Yath::Plugin'], ['renderer', 'classes', 'App::Yath::Renderer'], ['resource', 'classes', 'App::Yath::Resource']) {
            my ($group, $field, $type) = @$set;
            next unless $module->isa($type);
            $settings->$group->option($field => {}) unless $settings->$group->$field;
            my $args = $settings->$group->$field->{$module} //= [];
            next unless $module->can('args_from_settings');
            push @$args => $module->args_from_settings(settings => $settings, args => $args, group => $group, field => $field, type => $type);
        }
    }
}

sub run {
    my $self = shift;

    $self->clear_env();
    $self->process_args();

    my $settings = $self->{+SETTINGS};

    my $plugins = [];
    my $plugin_specs = $settings->yath->plugins;
    for my $pclass (keys %$plugin_specs) {
        require(mod2file($pclass));

        $pclass->sanity_checks();

        my $new_args = $plugin_specs->{$pclass};
        my $has_new  = $pclass->can('new');

        if ($new_args && @$new_args) {
            die "Plugin $pclass does not accept construction args.\n"          unless $has_new;
            die "Plugin $pclass args need to be an arrayref, got $new_args.\n" unless ref($new_args) eq 'ARRAY';
        }

        if ($has_new) {
            $new_args //= [];
            my $plugin = $pclass->new(@$new_args);
            $plugin->set_settings($settings);
            push @$plugins => $plugin
        }
        else {
            push @$plugins => $pclass;
        }
    }

    my $cmd_class = $self->command;
    $settings->yath->create_option(command => $cmd_class) if $cmd_class;

    $self->handle_debug();

    my $cmd = $cmd_class->new(
        settings     => $settings,
        args         => $self->argv,
        env_vars     => $self->{+ENV_VARS},
        option_state => $self->{+OPTION_STATE},
        plugins      => $plugins
    );

    warn "generate_run_dub found in '$cmd', this is no longer supported" if $cmd->can('generate_run_sub');

    return $self->run_command($cmd);
}

sub run_command {
    my $self = shift;
    my ($cmd) = @_;

    my $exit = $cmd->run($self);

    die "Command '" . $cmd->name() . "' did not return an exit value.\n"
        unless defined $exit;

    my $settings = $self->settings;

    if ($settings->check_group('workspace') && !$settings->workspace->keep_dirs) {
        remove_tree($settings->workspace->workdir, {safe => 1, keep_root => 0});

        # Fixme - breaks server with ephemeral db
        #remove_tree($settings->workspace->tmpdir,  {safe => 1, keep_root => 0});
    }

    return $exit;
}

sub include_options {
    my $self = shift;
    my ($type, $namespace) = @_;

    my $yath_s = $self->settings->yath;

    my $opt_scan    = $yath_s->scan_options->{options} // 1;
    my $type_scan   = $yath_s->scan_options->{$type}   // 1;
    return unless $opt_scan || $type_scan;

    my $opts = $self->{+OPTIONS};

    my $option_libs = find_libraries($namespace);

    for my $lib (sort keys %$option_libs) {
        local $@;
        my $ok = eval { require $option_libs->{$lib}; 1 };

        unless ($ok) {
            next if $self->deprecated_core($lib);

            chomp($@);
            warn "\n==== Failed to load module '$option_libs->{$lib}' ====\n$@\n==== End error for '$option_libs->{$lib}' ====\n\n";
            next;
        }

        next unless $lib->can('options');
        my $add = $lib->options;
        next unless $add;

        unless (blessed($add) && $add->isa('Getopt::Yath::Instance')) {
            warn "Module '$option_libs->{$lib}' is outdated, not loading options.\n"
                unless $ENV{'YATH_SELF_TEST'};

            next;
        }

        $opts->include($add);
    }
}

sub deprecated_core {
    my $self = shift;
    my ($class) = @_;

    no strict 'refs';

    return ${"$class\::DEPRECATED_CORE"} ? 1 : 0;
}

sub handle_debug {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $yath_options = $self->options;

    my $cmd_class = $self->{+COMMAND};
    my $cmd = $cmd_class ? $cmd_class->name : '';

    my $show_help;
    my $exit;
    if ($settings->yath->version) {
        $show_help = 0;
        print $self->version_info() . "\n\n";
        $exit //= 0;
    }

    if (!$cmd_class && !$settings->yath->help) {
        $show_help //= 1;
        $exit = 255;
    }

    if ($settings->yath->help || $show_help) {
        my $help = "\n";

        if (!$cmd_class && !$settings->yath->help) {
            $help .= "No command specified!\n\n";
        }

        my $group = $settings->yath->help;
        my %cli_params;
        $cli_params{group} = $group if $group && $group ne '1';
        $help .= $self->cli_help($yath_options, %cli_params);

        paged_print($help);

        $exit //= 0;
    }

    if (my $group = $settings->yath->show_opts) {
        my $out = "";
        $out .= "\nCommand selected: $cmd ($cmd_class)\n" if $cmd && $cmd_class;

        my @args = @{$self->argv};
        $out .= "\nargs: " . join(', ' => @args) . "\n" if @args;

        my $json = $group eq '1' ? encode_pretty_json($settings) : encode_pretty_json($settings->{$group} // "!! Invalid Group '$group' !!");

        $out .= "\nCurrent command line and config options result in these settings:\n";
        $out .= "$json\n";

        $out .= $self->_render_groups(
            title => 'If the above output is too much, you can limit it to specific option groups',
            param => '--show-opts=GROUP_NAME',
        ) if $group eq '1';

        paged_print($out);

        $exit //= 0;
    }

    if (defined $exit) {
        remove_tree($settings->workspace->workdir, {safe => 1, keep_root => 0}) if $settings->check_group('workspace');
        exit($exit);
    }
}

sub version_info {
    my $self = shift;

    my $out = <<"    EOT";

Yath version: $VERSION

Extended Version Info
    EOT

    my $plugin_libs = find_libraries('App::Yath::Plugin::*');

    my @vers = (
        [perl        => $^V],
        ['App::Yath' => App::Yath->VERSION],
        $self->command ? [$self->command, $self->command->VERSION // 'N/A'] : (),
        (
            map {
                eval { require(mod2file($_)); 1 }
                    ? [$_ => $_->VERSION // 'N/A']
                    : [$_ => 'N/A']
            } qw/Test2::API Test2::Suite Test::Builder Test2::Harness/,
        ),
        (
            map {
                eval { require($plugin_libs->{$_}); 1 }
                    && [$_ => $_->VERSION // 'N/A']
            } sort keys %$plugin_libs
        ),
    );


    $out .= join "\n" => table(
        header => [qw/COMPONENT VERSION/],
        rows   => [ grep { $_ } @vers ],
    );

    return $out;
}

sub clear_env {
    delete $ENV{HARNESS_IS_VERBOSE};
    delete $ENV{T2_FORMATTER};
    delete $ENV{T2_HARNESS_FORKED};
    delete $ENV{T2_HARNESS_IS_VERBOSE};
    delete $ENV{T2_HARNESS_JOB_IS_TRY};
    delete $ENV{T2_HARNESS_JOB_NAME};
    delete $ENV{T2_HARNESS_PRELOAD};
    delete $ENV{T2_STREAM_DIR};
    delete $ENV{T2_STREAM_FILE};
    delete $ENV{T2_STREAM_JOB_ID};
    delete $ENV{TEST2_JOB_DIR};
    delete $ENV{TEST2_RUN_DIR};

    # If Test2::API is already loaded then we need to keep these.
    delete $ENV{TEST2_ACTIVE} unless $INC{'Test2/API.pm'};
    delete $ENV{TEST_ACTIVE}  unless $INC{'Test2/API.pm'};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath - FIXME

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

