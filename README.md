# torturedrive
Script to run a set of tests on a hard drive using fio and/or spdk

Idea is to provide a series of reproduceable tests that can be let run
in sequence for as long as it takes (maybe hours or days) while we do
something more useful with our time. At the end of the run we have
a file we can use to build tables from comparing all the different tests.

## Aknowledgements

1. The basic structure for this code was copied from 
[Sennajox](https://github.com/sennajox) code, https://gist.github.com/sennajox/3667757. I was planning on doing something similar but I really liked how the code was structured. Thanks!
1. The command line parsing arguments was stolen from a [stackoverflow thread](https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash), as it was more clever than I could come up with without relying on python.
