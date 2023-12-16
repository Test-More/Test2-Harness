package App::Yath;
use strict;
use warnings;

our $VERSION = '2.000000';

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
};

use Getopt::Yath();
use Getopt::Yath::Settings;
use Getopt::Yath::Term qw/USE_COLOR color fit_to_width/;

use App::Yath::Options::Yath;

use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;
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
    return $self->{+COLOR} = $self->{+SETTINGS}->term->color ? 1 : 0;
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
    my $cmd = $cmd_class ? $cmd_class->name : 'COMMAND';

    my $help = "";
    if ($cmd_class) {
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

        my @desc = map { fit_to_width(" ", $_) } split /\n\n/, $cmd_class->description;
        $help .= join "\n\n" => @desc;
    }

    my $opts = $options->docs('cli', groups => {':{' => '}:'}, group => $params{group}, settings => $settings, color => $self->use_color);

    my $script = File::Spec->abs2rel($settings->yath->script // $0);
    my $usage = '';
    my $append = '';
    if ($self->use_color) {
        $usage = join ' ' => (
            color('bold white') . "USAGE:" . color('reset'),
            color('white') . $script,
            color('cyan') . "[YATH OPTIONS]",
            color('bold green') . $cmd . color('reset'),
            color('cyan') . "[OPTIONS FOR COMMAND AND/OR YATH]",
            color('yellow') . "[--]",
        );

        $append = ($cmd_class && $cmd_class->args_include_tests) ? ' ' . join " " => (
            color('white') . "[ARGUMENTS/TESTS]",
            color('green') . "[TEST :{ ARGS TO PASS TO TEST }:]",
            color('magenta') . "[:: PASS-THROUGH]" . color('reset')
        ) : color('white') . " [ARGUMENTS]";
    }
    else {
        $usage = "USAGE: $script [YATH OPTIONS] $cmd [OPTIONS FOR COMMAND AND/OR YATH] [--]";
        $append = ($cmd_class && $cmd_class->args_include_tests) ? " [ARGUMENTS/TESTS] [TEST :{ ARGS TO PASS TO TEST }:] [:: PASS-THROUGH]" : " [ARGUMENTS]";
    }

    my $end = "";
    if ($settings->yath->help && !$params{group}) {
        $end = $self->_render_groups(
            title => 'If the above help output is too much, you can limit it to specific option groups',
            param => '--help=GROUP_NAME',
        );
    }

    return "${usage}${append}\n${help}\n${opts}\n${end}";
}

sub _strip_color {
    my $self = shift;
    my ($colors, $line) = @_;
    return $line unless $self->use_color;

    my $pattern = join '|' => map { "\Q$_\E"} values %$colors;
    $line =~ s/($pattern)//g;

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

sub process_args {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    # First process the global yath args
    my $yath_options = $self->options;

    my ($env, $cleared, $modules) = ({}, {}, {});
    my $state = $yath_options->process_args(
        $self->argv,

        env      => $env,
        cleared  => $cleared,
        modules  => $modules,
        settings => $settings,
        stops    => ['--', '::'],
        groups   => {':{' => '}:'},

        skip_posts => 1,
        stop_at_non_opts => 1,

        invalid_opt_callback => sub {
            my ($opt) = @_;
            print STDERR "\nERROR: '$opt' is not a valid yath option.\n       (Command specific options must come after the command, did you forget to specify a command?)\n\n" . $self->cli_help($yath_options);
            exit 255;
        },
    );

    my $load_cmd = sub {
        my ($cmd) = @_;

        my $cmd_class = "App::Yath::Command::$cmd";
        my $cmd_file = mod2file($cmd_class);
        unless (eval { require $cmd_file; die "$cmd_class does not subclass App::Yath::Command.\n" unless $cmd_class->isa('App::Yath::Command'); 1 }) {
            my $eq80 = '=' x 80;
            print STDERR "\nERROR: '$cmd' ($cmd_class) does not look like a valid command:\n${eq80}\n$@${eq80}\n";
            exit 255;
        }

        $yath_options->include($cmd_class->options) if $cmd_class->can('options');
        $settings->yath->create_option(command => $cmd_class);
        $self->{+COMMAND} = $cmd_class;

        $self->include_options('plugins'  => 'App::Yath::Plugin::*')   if $cmd_class->load_plugins();
        $self->include_options('resource' => 'App::Yath::Resource::*') if $cmd_class->load_resources();
        $self->include_options('renderer' => 'App::Yath::Renderer::*') if $cmd_class->load_renderers();
    };

    if (my $file = $settings->yath->load_settings) {
        my $json = read_file($file);
        my $raw = decode_json($json);
        $raw->{yath} = { %{$settings->yath->TO_JSON}, dev_libs => $raw->{yath}->{dev_libs},  };
        $settings = $self->{+SETTINGS} = Getopt::Yath::Settings->new(%$raw);

        my $cmd = $state->{stop} or die "No command provided.\n";
        $load_cmd->($cmd);
    }

    if (my $cmd = $state->{stop}) {
        if ($cmd eq '--' || $cmd eq '::') {
            print STDERR "\nERROR: '$cmd' must be used after the yath sub-command.\n\n" . $self->cli_help($yath_options);
            exit 255;
        }

        $load_cmd->($cmd);

        $state = $yath_options->process_args(
            $state->{remains},

            env      => $env,
            cleared  => $cleared,
            modules  => $modules,
            settings => $settings,
            stops    => ['--', '::'],
            groups   => {':{' => '}:'},

            skip_non_opts => 1,

            invalid_opt_callback => sub {
                my ($opt) = @_;
                print STDERR "\nERROR: '$opt' is not a valid yath or '$cmd' command option.\n\n" . $self->cli_help($yath_options);
                exit 255;
            },
        );
    }

    $self->{argv} = [@{$state->{skipped}}, $state->{stop} ? $state->{stop} : (), @{$state->{remains}}];

    $self->{+ENV_VARS} = $env;
    $self->{+OPTION_STATE} = $state;

    for my $module (keys %$modules) {
        for my $set (['yath', 'plugins', 'App::Yath::Plugin'], ['renderer', 'classes', 'App::Yath::Renderer'], ['resource', 'classes', 'App::Yath::Resource']) {
            my ($group, $field, $type) = @$set;
            next unless $module->isa($type);
            my $args = $settings->$group->$field->{$module} //= [];
            next unless $module->can('args_from_settings');
            push @$args => $module->args_from_settings(settings => $settings, args => $args, group => $group, field => $field, type => $type);
        }
    }
}

sub run {
    my $self = shift;

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
            push @$plugins => $pclass->new(@$new_args);
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
        next if $lib eq 'App::Yath::Plugin::Notify';
        my $ok = eval { require $option_libs->{$lib}; 1 };
        unless ($ok) {
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

        if (eval { require IO::Pager; 1 }) {
            local $SIG{PIPE} = sub {};
            my $pager = IO::Pager->new(*STDOUT);
            $pager->print($help);
        }
        else {
            print $help;
        }

        $exit //= 0;
    }

    if (my $group = $settings->yath->show_opts) {
        print "\nCommand selected: $cmd ($cmd_class)\n" if $cmd && $cmd_class;

        my @args = @{$self->argv};
        print "\nargs: " . join(', ' => @args) . "\n" if @args;

        my $out = $group eq '1' ? encode_pretty_json($settings) : encode_pretty_json($settings->{$group} // "!! Invalid Group '$group' !!");

        print "\nCurrent command line and config options result in these settings:\n";
        print "$out\n";

        print $self->_render_groups(
            title => 'If the above output is too much, you can limit it to specific option groups',
            param => '--show-opts=GROUP_NAME',
        ) if $group eq '1';


        $exit //= 0;
    }

    exit($exit) if defined $exit;
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
            } qw/Test2::API Test2::Suite Test::Builder Test2::Harness Test2::Harness::UI/,
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
        rows   => \@vers,
    );

    return $out;
}

warn "Clear Env used to be done...";

1;
