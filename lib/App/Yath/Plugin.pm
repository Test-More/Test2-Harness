package App::Yath::Plugin;
use strict;
use warnings;

our $VERSION = '0.001096';

sub options {}

sub pre_init {}

sub post_init {}

sub post_run {}

sub find_files {}

sub munge_files {}

sub block_default_search {}

sub claim_file {}

sub inject_run_data {}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin - Parent of App::Yath plugins

=head1 SYNOPSIS

  package App::Yath::Plugin::SOME_PLUGIN;
  use strict;
  use warnings;

  use parent 'App::Yath::Plugin';

  sub find_files {
    my @files;
    # ...

    return \@files;
  }

  1;

  # which can then be used when invoking `yath`:

  $ yath -pSOME_PLUGIN


=head1 DESCRIPTION

L<App::Yath>'s processing can be hooked into at specific points
by plugins. These plugins can extend or change its default processing.

This module provides an empty skeleton plugin. It's meant to be used
as a parent class for any custom plugins.

=head2 Instantiation

In case a plugin has a C<new> function, it is assumed to be a constructor
and an instance will be created using any parameters provided on the command
line:

  $ yath -pSOME_PLUGIN=abc,1,dev,delta

  # causes the 'new' function to be invoked as:
  #  App::Yath::Plugin::SOME_PLUGIN->new( abc => 1, dev => 'delta' );

Without C<new>, no instance will be created and all entry points will be
assumed to be class methods, e.g. C<find_files> will be called as

  App::Yath::Plugin::OTHER_PLUGIN->find_files(\@files);


=head1 FUNCTIONS

=head2 options($command, $settings)

This hook is called immediately after plugin instantiation.

Returns a list of hash references to be added to the list of built-in
options. Each hashref contains the following keys:

=over 4

=item * spec

=item * field

=item * used_by

=item * section

=item * usage

=item * summary

=item * long_desc

=item * action

=item * normalize

=item * default

=back

C<$command> represents the command being invoked on the C<yath> command
line (a C<App::Yath::Command::*> instance).

##todo: document what $settings is...

=head2 pre_init($command, $settings)

This hook is called after plugin instantiation and before C<yath>
initialization; that is, even before command line options are fully
processed.

This hook has no specified return value.

##todo: document what $settings is...

=head2 post_init($command, $settings)

This hook is called after instantiation when the working directory
has been created.

This hook has no specified return value.

=head2 find_files($command, \@search)

Returns a list of L<Test2::Harness::Util::TestFile> instances to be
added to the list of files to be handled.

The array reference C<\@search> contains a list of search paths
(directory and/or file names).

=head2 munge_files(\@files)

C<\@files> is a reference to an array of L<Test2::Harness::Util::TestFile>
instances.

This hook is called after the list of files to be processed, has been
compiled. It allows each plugin to enhance entries by replacing the existing
instances with new instances in the array.

This is the hook where a plugin has the opportunity to specify an alternate
job runner, much like Test::Harness's L<TAP::Parser::SourceHandler>, by
specifying a C<via> argument in the C<queue_args>:

  for my $tf (@$files) {
     if ($tf->file =~ m/[.]feature$/) {
       $tf = Test2::Harness::Util::TestFile->new(
          %$tf, queue_args => [ via => [ 'SqlFork', 'SqlIPC' ] ]);
     }
  }

=head2 claim_file($file)

Returns a path or undef.

By returning a path (most often the C<$file> input parameter), this
function stops default handling of C<$file>. This means that when
C<$file> is a directory, subdirectories won't be searched. When C<$file>
is a file path, that file won't be added to the list of test files
handled by Yath. Presumably, the plugin has a mechanism to handle
the C<$file> itself.

=head2 block_default_search($settings)

NOTE: Always a class method, even for instantiated plugins.

Returns a boolean value which - when true - blocks the default search
mechanism for files to be executed.

###todo: document what $settings is...

=head2 inject_run_data(meta => \%meta, fields => \@fields, run => $run)

This plugin allows annotation of runs by injecting run meta data through
the modification of the values of C<%meta> and C<@fields>.

This hook has no specified return value.


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
