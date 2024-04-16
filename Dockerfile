FROM ubuntu:18.10 as base

ENV DEBIAN_FRONTEND=noninteractive
RUN ["apt-get", "update"]
RUN ["apt-get", "install", "-y", "apt-utils"],
RUN ["apt-get", "upgrade", "-y"]

# cpanm will need this later
RUN ["apt-get", "install", "-y", "build-essential"],

# postgresql
RUN ["apt-get", "install", "-y", "postgresql", "postgresql-contrib", "postgresql-client"]

# We want to update perl, install cpanminus, and get the dbd-pg dependancies installed.
RUN ["apt-get", "install", "-y", "perl", "cpanminus", "libdbd-pg-perl"]

# Needed for building/installing modules later
RUN ["apt-get", "install", "-y", "rsync", "uuid-dev", "libcurl4-gnutls-dev", "libncurses5-dev", "libreadline-dev"],

# Needed for postgres tools
RUN ["apt-get", "install", "-y", "locales-all"]

# Sometimes cpanminus has an issue installing DBIx::Class due to order of
# modules. Install the system packages to get the requirements all in place,
# cpanm will upgrade it next.
RUN ["apt-get", "install", "-y", "libdbix-class-perl", "libdbix-class-uuidcolumns-perl", "libdbix-class-schema-config-perl", "libdbix-class-schema-loader-perl", "libdbix-class-timestamp-perl", "libdbix-class-tree-nestedset-perl", "libnet-ssleay-perl", "libipc-run-perl", "libipc-run3-perl", "libuuid-perl", "libdata-uuid-libuuid-perl", "libxml-parser-perl", "libxml-libxml-perl", "libterm-readline-perl-perl", "libterm-readline-gnu-perl"],

RUN ln -s /usr/lib/postgresql/10/bin/* /usr/bin/ 2>/dev/null || true

RUN ["cpanm", "LWP"]
RUN ["cpanm", "App::cpanminus"]
RUN ["cpanm", "File::ShareDir::Install"]
RUN ["cpanm", "-v", "Test2::Harness"]

# Module tests run commands that cannot be run as root, but installation must be done as root... sigh
RUN ["cpanm", "-n", "-v", "DBIx::QuickDB"]

RUN ["cpanm", "--installdeps", "-v", "Test2::Harness::UI"]


RUN groupadd -g 999 appuser && useradd -r -u 999 -g appuser appuser

FROM base as demo

ADD . /app

# In case new deps were added
RUN ["cpanm", "--installdeps", "-v", "/app"]

RUN ["chown", "-R", "999:999", "/app"]
USER appuser

ENV T2_HARNESS_UI_ENV=dev
EXPOSE 8081
WORKDIR /app
ENTRYPOINT ["perl", "-I", "/app/lib", "/app/demo/demo.pl"]
