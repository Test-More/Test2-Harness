use strict;
use warnings;

use Test2::Require::AuthorTesting;
use Test2::Require::Module 'Test::Spelling';
use Test::Spelling;

my @stopwords;
for (<DATA>) {
    chomp;
    push @stopwords, $_
        unless /\A (?: \# | \s* \z)/msx;    # skip comments, whitespace
}

print "### adding stopwords @stopwords\n";

add_stopwords(@stopwords);
local $ENV{LC_ALL} = 'C';
set_spell_cmd('aspell list -l en');
all_pod_files_spelling_ok;

__DATA__
## personal names
Bowden
Daly
EXODIST
Eryq
Fergal
Glew
Granum
Oxley
Pritikin
Schwern
Skoll
Slaymaker
ZeeGee
binkley
dfs

## proper names
Fennec
ICal
xUnit

## test jargon
Diag
EventFacet
EventFacets
TODO
diag
isnt
renderers
subtest
subtests
testsuite
testsuites
todo
todos
untestable
xt

## computerese
AutoList
AutoMap
BUF
Getter
HASHBASE
HashBase
IPC
JSONL
NBYTES
POS
PRELOAD
Postfix
Preload
Reinitializes
SCALARREF
SHBANG
SHM
SUBLCASSES
Setter
SharedJobSlots
TIEHANDLE
TimeTracker,
TypeName
UI
Unterminated
VMS
YATH
YESNO
Yath
YathUI
ansi
autofill
blackbox
bz
bzip
cli
cmd
codeblock
combinatorics
daemonize
dev
dir
durations
env
getline
getlines
getopt
getpos
getters
heisenbug
html
jsonl
loadim
mem
pPlugin
param
perl-qa
perlish
predeclaring
preload
preloaded
preloading
preloads
qvf
rc
rebless
refactoring
refcount
renderer
setpos
sha
shm
sref
subevent
subevents
testability
tie-ing
timetracker
tlib
tmpdir
unoverload
unparsed
utils
vmsperl
vv
workdir
yaml
yath


## other jargon, slang
17th
AHHHHHHH
Dummy
ESYNC
Hmmm
IMMISCIBLE
POSTEXIT
SIGALRM
SIGHUP
SIGINT
SIGTERM
SIGUSR1
SIGUSR2
backfill
cid
globalest
integrations
lff
muxed
pid
tid
webhook


## Spelled correctly according to google:
judgement
recognise
recognises
