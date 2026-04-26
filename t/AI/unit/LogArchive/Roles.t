use Test2::V0;
use App::Yath2::LogArchive::Role::Source;
use App::Yath2::LogArchive::Role::Writer;

package Fake::Source;
use Role::Tiny::With;
with 'App::Yath2::LogArchive::Role::Source';
sub read_file  { die 'nope' }
sub has_file   { die 'nope' }
sub list_files { die 'nope' }
sub close      { die 'nope' }
sub viable     { 1 }
sub dict_bytes { undef }

package Fake::Writer;
use Role::Tiny::With;
with 'App::Yath2::LogArchive::Role::Writer';
sub write_archive { die 'nope' }
sub viable        { 1 }

package main;
ok(Role::Tiny::does_role('Fake::Source', 'App::Yath2::LogArchive::Role::Source'), 'Source role composed');
ok(Role::Tiny::does_role('Fake::Writer', 'App::Yath2::LogArchive::Role::Writer'), 'Writer role composed');

done_testing;
