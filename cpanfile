# This file is generated by Dist::Zilla::Plugin::CPANFile v6.024
# Do not edit this file directly. To change prereqs, edit the `dist.ini` file.

requires "Carp" => "0";
requires "Clone" => "0";
requires "Crypt::Eksblowfish::Bcrypt" => "0";
requires "DBI" => "0";
requires "DBIx::Class::Helper::ResultSet::RemoveColumns" => "0";
requires "DBIx::Class::InflateColumn::DateTime" => "0";
requires "DBIx::Class::InflateColumn::Serializer" => "0";
requires "DBIx::Class::InflateColumn::Serializer::JSON" => "0";
requires "DBIx::Class::Schema::Loader" => "0";
requires "DBIx::Class::Tree::AdjacencyList" => "0";
requires "DBIx::Class::UUIDColumns" => "0";
requires "DBIx::QuickDB" => "0.000020";
requires "Data::GUID" => "0";
requires "DateTime" => "0";
requires "DateTime::Format::MySQL" => "0";
requires "DateTime::Format::Pg" => "0";
requires "Email::Sender::Simple" => "0";
requires "Email::Simple" => "0";
requires "Email::Simple::Creator" => "0";
requires "File::ShareDir" => "0";
requires "File::Temp" => "0";
requires "HTTP::Tiny" => "0";
requires "IO::Compress::Bzip2" => "0";
requires "IO::Uncompress::Bunzip2" => "0";
requires "IO::Uncompress::Gunzip" => "0";
requires "Importer" => "0.025";
requires "JSON::MaybeXS" => "0";
requires "List::Util" => "0";
requires "MIME::Base64" => "0";
requires "Net::Domain" => "0";
requires "Plack::App::Directory" => "0";
requires "Plack::App::File" => "0";
requires "Plack::Builder" => "0";
requires "Plack::Handler::Starman" => "0";
requires "Plack::Middleware::DBIx::DisconnectAll" => "0";
requires "Plack::Runner" => "0";
requires "Router::Simple" => "0";
requires "Scalar::Util" => "0";
requires "Statistics::Basic" => "0";
requires "Test2" => "1.302164";
requires "Test2::API" => "1.302166";
requires "Test2::Formatter::Test2::Composer" => "0";
requires "Test2::Harness" => "1.000149";
requires "Test2::Harness::Util::HashBase" => "0";
requires "Test2::Harness::Util::JSON" => "0";
requires "Test2::Harness::Util::UUID" => "0";
requires "Test2::Tools::QuickDB" => "0";
requires "Test2::Tools::Subtest" => "0";
requires "Test2::Util" => "0";
requires "Test2::Util::Facets2Legacy" => "0";
requires "Test2::V0" => "0.000126";
requires "Test::More" => "0";
requires "Text::Xslate" => "0";
requires "Time::Elapsed" => "0.33";
requires "Time::HiRes" => "0";
requires "base" => "0";
requires "constant" => "0";
requires "parent" => "0";
requires "perl" => "5.008009";
suggests "Cpanel::JSON::XS" => "0";
suggests "DBD::Pg" => "0";
suggests "DBD::mysql" => "0";
suggests "DBIx::Class::Storage::DBI::mysql::Retryable" => "0";

on 'test' => sub {
  requires "HTTP::Tiny::UNIX" => "0";
};

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
  requires "File::ShareDir::Install" => "0.06";
};

on 'develop' => sub {
  requires "Test::Pod" => "1.41";
};
