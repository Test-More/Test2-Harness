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
binkley
Bowden
Daly
dfs
Eryq
EXODIST
Fergal
Glew
Granum
Oxley
Pritikin
Schwern
Skoll
Slaymaker
ZeeGee

## proper names
Fennec
ICal
xUnit

## test jargon
Diag
diag
isnt
subtest
subtests
testsuite
testsuites
TODO
todo
todos
untestable
EventFacet
EventFacets
renderers
xt

## computerese
blackbox
BUF
codeblock
combinatorics
dir
getline
getlines
getpos
Getter
getters
HashBase
heisenbug
IPC
NBYTES
param
perlish
perl-qa
POS
predeclaring
rebless
refactoring
refcount
Reinitializes
SCALARREF
setpos
Setter
SHM
sref
subevent
subevents
testability
TIEHANDLE
tie-ing
unoverload
VMS
vmsperl
YESNO
ansi
html
HASHBASE
renderer
SHBANG
JSONL
YATH
jsonl
rc
tmpdir
utils
workdir
Postfix
env
bz
bzip
preloaded
Yath
vv
PRELOAD
yath
preloads
Preload
pPlugin
tlib
preload
loadim
preloading
shm
qvf
mem


## other jargon, slang
17th
AHHHHHHH
Dummy
globalest
Hmmm
cid
tid
pid
SIGINT
SIGALRM
SIGHUP
SIGTERM
SIGUSR1
SIGUSR2
webhook
integrations
IMMISCIBLE
POSTEXIT
lff
backfill
ESYNC
muxed


## Spelled correctly according to google:
recognise
recognises
judgement
