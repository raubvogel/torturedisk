# torturedisk
Script to run a set of tests on a hard drive using fio and/or spdk

Idea is to provide a series of reproduceable tests that can be allowed to 
run in sequence for as long as it takes (maybe hours or days) while we do
something more useful with our time. At the end of the run we have
a file we can use to build tables from comparing all the different tests.

## Installation:
This is a single script in bash; you can download it anyway you want. However,
you will need fio and/or spdk:

1. If testing normal hard drives, be them spinny or SSDs, you only need fio.
   - You can use the fio package for your OS if available
   - OR, you can download [FIO](https://github.com/axboe/fio) and compile it yourself
1. If testing NVMe hard drives, you will need spdk. 
   -  Download [SPDK](https://github.com/spdk/spdk) and build it. There might be packages available for your OS but I do not know where they are.
   -  Find the PCI path for the NVMe hard drive you want to test
1. If you want to run `spdk+fio` tests (run fio with spdk support), you need both.
   - You will need to compile fio before compiling spdk since you will need to provide its path during configuration..

## NOTEs:

1. I do need to write better documentation!
1. However, this is not about how to use SPDK or FIO or whatever. There are 
already great docs on how to use [FIO](https://fio.readthedocs.io/en/latest/fio_doc.html) and [SPDK](https://spdk.io/doc/index.html); let's not reinvent the wheel, shall we?
1. This script was originally created in black and green.

### What is a device?

A device here a storage device represented either as a block device
(`/dev/sdb` or `/data/test.dat` or a PCI address (`0000:63:00.0`) in case of 
NVMe hard drives.

## Examples:
1. Test the block device `/dev/sdb` using default settings (`fio_libaio`, 
) and creating the directory `test_results` where results will be saved.
Output file will be `test_results/test_results.csv`

**WARNING:** This will destroy the filesystem on `/dev/sdb`
   
```bash
torturedisk -d /dev/sdb -o test_results
```

2. Test a file, `test.dat` inside a filesystem mounted in `/data`. This
might represent a raw disk you plan on feeding to a vm guest. Or just a
non-destructive way to have a general idea of performance for a drive.

You can create the disk using `dd` or `fallocate`. I like to use `dd`
since I can specify which data I want to initialize it with, works on most
distros of Linux, UNIX, and OSX, and [I can make large images](https://unixwars.blogspot.com/2018/03/thoughts-on-creating-large-iso-using-dd.html):

```bash
fallocate -l 1G /data/test.dat
```

And business as usual:
```bash
torturedisk -d /data/test.dat -o test_results
```

3. Test the NVMe device with PCI address `0000:63:00.0` using spdk+fio, 
multiple combinations of read/writes (100% read 0% write (read-only), 
70% r 30% w, 30% r 70% w, 0% r 100% write (write-only)), IO Depth = 128,
until achieving steady state being defined as having the IOPS slope <= 0.3%.

```bash
time ./torturedisk.sh -d '0000:63:00.0'  -o $PWD/results-ss_02 -s iops -i 128 -e "spdk" -m "100 70 30 0"
```

You must bind the hard drive **first** (the path to the spdk directory is
based on where **I** installed it):

```bash
PCI_WHITELIST='0000:63:00.0' HUGEMEM=8192 $HOME/dev/spdk/scripts/setup.sh
```

## Aknowledgements

1. The basic structure for this code was copied from 
[Sennajox](https://github.com/sennajox)'s code, https://gist.github.com/sennajox/3667757. I was planning on doing something similar but I really liked how the code was structured. Thanks!
1. The command line parsing arguments was stolen from a [stackoverflow thread](https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash), as it was more clever than I could come up with without relying on python.
1.  Jared Walton <jawalking@gmail.com> for showing that fio can monitor when
data has reached steady state and how to tell it to do so.
