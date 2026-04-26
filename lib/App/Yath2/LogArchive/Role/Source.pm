package App::Yath2::LogArchive::Role::Source;
use strict;
use warnings;
use Role::Tiny;

requires qw/read_file has_file list_files close viable dict_bytes/;

1;
