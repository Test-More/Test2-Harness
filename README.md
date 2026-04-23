# NAME

App::Yath::Script - Script initialization and utility functions for Test2::Harness

# SYNOPSIS

The `yath` script uses this module as its entry point:

    #!/usr/bin/perl
    use strict;
    use warnings;

    BEGIN {
        return if $^C;
        require App::Yath::Script;
        App::Yath::Script::do_begin();
    }

    exit(App::Yath::Script::do_runtime());

# DESCRIPTION

This module provides the initial entry point for the `yath` script. It handles
script discovery, configuration loading, version detection, and delegation to
version-specific script modules (`App::Yath::Script::V{X}`).

During the `BEGIN` phase, `do_begin()` locates `.yath.rc` and
`.yath.user.rc` configuration files, determines the harness version to use,
and delegates to the appropriate `App::Yath::Script::V{X}` module. At
runtime, `do_runtime()` hands off execution to that module.

## Version Detection

When no configuration file is found, the latest installed
`App::Yath::Script::V{X}` module is used automatically (`V0` is excluded
from auto-detection since it is reserved for script validation).

The version is determined by the configuration filename using the following
priority (highest first) in each directory searched:

1. A `.yath.rc` symlink whose target filename matches `.yath.v#.rc` -- the
version is extracted from the target name. This lets projects keep a stable
`.yath.rc` name while pointing at the versioned file.
2. An explicitly versioned file `.yath.v#.rc` (e.g. `.yath.v2.rc`).
3. A plain `.yath.rc` (not a symlink to a versioned file) -- defaults to **1**
for backwards compatibility with existing [Test2::Harness](https://metacpan.org/pod/Test2%3A%3AHarness) projects.

The same priority applies to user-level configuration (`.yath.user.rc` /
`.yath.user.v#.rc`).

If both project-level and user-level configuration files specify a version,
the user-level version takes precedence. This allows individual developers to
override the project-level version when needed.

# PRIMARY API

These are the main entry points used by the `yath` script:

- do\_begin()

    Called during `BEGIN`. Discovers the script path, injects include paths,
    seeds `PERL_HASH_SEED` for reproducibility, loads `.yath.rc` /
    `.yath.user.rc` configuration files, determines the harness version, and
    delegates to `App::Yath::Script::V{X}->do_begin(...)`.

- $exit = do\_runtime()

    Called after `BEGIN`. Delegates to `App::Yath::Script::V{X}->do_runtime()`
    and returns the exit code.

# EXPORTS

All exports are optional (via [Importer](https://metacpan.org/pod/Importer)).

- $script\_file = script()

    Returns the path to the currently executing script file.

- $yath\_module = module()

    Returns the name of the currently loaded `App::Yath::Script::V{X}` module.

- do\_exec(\\@argv)

    Re-executes the current script with the given arguments. Sets the
    `T2_HARNESS_INCLUDES` environment variable to preserve the current `@INC`.

- $clean\_path = clean\_path($path)
- $clean\_path = clean\_path($path, $absolute)

    Converts a path to an absolute, normalized form. By default resolves symbolic
    links using `realpath`. Pass a false second argument to skip realpath
    resolution.

- $full\_path = find\_in\_updir($file)

    Searches for a file starting from the current directory and moving up through
    parent directories until found. Returns the full path to the file or `undef`
    if not found.

- $file = mod2file($mod)

    Converts a module name (e.g., `App::Yath::Script`) to a file path
    (e.g., `App/Yath/Script.pm`).

# SOURCE

The source code repository for Test2-Harness can be found at
[http://github.com/Test-More/Test2-Harness/](http://github.com/Test-More/Test2-Harness/).

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See [http://dev.perl.org/licenses/](http://dev.perl.org/licenses/)
