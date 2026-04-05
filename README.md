# NAME

App::Yath::Script - Script initialization and utility functions for Test2::Harness

# DESCRIPTION

This module provides the initial entry point for the yath script. It handles
script discovery, configuration loading, version detection, and delegation to
version-specific script modules (App::Yath::Script::V{X}).

It also provides utility functions for path manipulation, finding files in
parent directories, and module-to-file conversion.

# EXPORTS

- $script\_file = script()

    Returns the path to the currently executing script file.

- $yath\_module = module()

    Returns the name of the currently loaded App::Yath::Script::V{X} module.

- do\_exec(\\@ARGV)

    Re-executes the current script with the given arguments. Sets
    `T2_HARNESS_INCLUDES` environment variable to preserve the current `@INC`.

- $clean\_path = clean\_path($unclean\_path)
- $clean\_path = clean\_path($unclean\_path, 0)

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
