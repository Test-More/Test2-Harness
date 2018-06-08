use Plack::App::Directory;
Plack::App::Directory->new({ root => "./" })->to_app;
