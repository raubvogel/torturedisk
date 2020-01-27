#!/bin/bash

##
# Torturedisk
#
# RELEASE: 0.2.0.
# 0.1.0. Initial release
# 0.2.0. Add fio+spdk support
#
# REQUIREMENTS:
# - If running fio with libiaio
#   - You can use the fio package for your OS if available
#   - OR, you can compile fio (https://github.com/axboe/fio) yourself
#
# REQUIREMENTS:
# - If running fio with libiaio
#   - You can use the fio package for your OS if available
#   - OR, you can compile fio (https://github.com/axboe/fio) yourself
#
# 
# - If running spdk+fio,
#   1. Download spdk (https://github.com/spdk/spdk) and build it. 
#      Note you will also need to compile fio (https://github.com/axboe/fio)
#   2. Find the PCI path for the NVMe hard drive you want to test
#   3. Run this script providing the path to where you built spdk 
#
# NOTE:
# 1. Job types (rw=)
#    read: sequential read
#    write: sequential write
#    randread: random read
#    randwrite: random write
#

usage()
{
   program_name=$1

cat << EOF
$program_name: Run a set of disk performance tests and save the results
in a .csv-formatted file.

Usage: $program_name -d dev -o outdir [-i iodepth] [-e ioengine]"

Where:

   -d/--device: Name of the device. 
     If ioengine=/path/to/spdk, device is the PCI path to NVMe device
   -o/--outdir: Name of the directory to save all the logs and the summary
     file. 
     Summary filename is "$outdir.result" inside the directory $outdir.
   -i/--iodepth: IO Depth. Default is 8
   -e/--ioengine: IO engine. 
     Accepted values: libaio, spdk
     Default is libaio.
   -m|--mixreads: Rate between reads and writes
     If you want to enter and array enter it in quotes: "100 70 50 25 30"
     Default: "70 50 30"
 
Arguments can be given in any order provided they have their required flags.
dev and outdir are required.

Example 1: Testing the whole block device. 
WARNING: This will destroy the filesystem on the target block device!!!
   $program_name -d /dev/sdb -o test_results
   
Example 2: Testing a file inside a filesystem mounted in /data

   fallocate -l 1G /data/test.dat
   $program_name -d /data/test.dat -o test_results

EOF
    exit 1
}

# Constants and default values
FIOPATH=/root/dev/fio
FIO=$FIOPATH/fio
SPDKPATH=/root/dev/spdk

RUNTEST="$FIO" 

IOENGINE="libaio"
IOENGINEPATH="$IOENGINE"
IODEPTH=8

RUNTIME=30
BLOCK_SIZES=(512 4K 8K 16K 64K 128K 256K 512K)
JOBS=(write randwrite read randread randrw)

# if you test randrw, you need to specify the rwmixreads in this array
RWMIXREADS=(70 50 30)

# Functions

gen_job_file() 
{
    # gen_job_file job block_size [rwmixread]
    job=$1
    outjob=$OUTDIR/$job

    block_size=$2
    echo "[global]" > $outjob
    echo "bs=$block_size" >> $outjob
    echo "direct=1" >> $outjob
    echo "rw=$job" >> $outjob
    echo "ioengine=$IOENGINEPATH" >> $outjob
    echo "iodepth=$IODEPTH" >> $outjob

    if [ -z ${SSTATETYPE+x} ]
    then
       echo "runtime=$RUNTIME" >> $outjob
    else
       echo "runtime=24h" >> $outjob
       echo "steadystate_duration=1800" >> $outjob
       echo "steadystate=iops_slope:0.3%" >> $outjob
    fi

    if [ "$job" == "randwrite" -o "$job" == "randread" -o "$job" == "randrw" ]; then
        echo "randrepeat=0" >> $outjob
    fi
    echo "[test]" >> $outjob
    if [ "$job" == "randrw" ]; then
        echo "rwmixread=$3" >> $outjob
    fi

    if [ "$IOENGINE" == "spdk" ]; then
        echo 'thread=1' >> $outjob
        echo "filename=trtype=PCIe traddr=$(echo $DEV|tr \: \.) ns=1" >> $outjob
    else
        echo "filename=$DEV" >> $outjob
    fi

}

cleanup() 
{
    for job in "${JOBS[@]}"
    do
        rm -f $OUTDIR/$job
    done
    rm -f *.tmp
}

run_test() 
{
    job=$1
    block_size=$2
    if [ $# -lt 3 ]; then
        output="$OUTDIR/fio.$job.$block_size.1.log"
    else
        output="$OUTDIR/fio.$job.$block_size.$3.1.log"
    fi

    $RUNTEST --output="$output" $OUTDIR/$job

}
select_bw() 
{
    index=$1
    file=$2
    # unit:KB/S
    bw=$(fgrep "BW=" "$file" | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    bw_array[$index]=",$bw"
}

select_iops() 
{
    index=$1
    file=$2
    # iops=`grep "IOPS=" "$file" | gawk -F[=,]+ '{print $2}'`
    iops=$(grep "IOPS=" "$file" | gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1024)} else {print $2}}')
    iops_array[$index]=",$iops"
}

select_lat() 
{
    index=$1
    file=$2
    # unit:ms
    line=`grep "lat" "$file" | grep "avg" | grep -v -E "clat|slat"`
    lat=`echo $line | gawk -F[=,:]+ '{if($1 == "lat (usec)") {printf("%.2f", $7/1000);} else {printf("%.2f", $7)} }'`
    lat_array[$index]=",$lat"
}

select_bw_rw() 
{
    index=$1
    file=$2
    # unit:KB/S
    bw_read=$(fgrep "BW=" "$file" | grep read | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    bw_write=$(fgrep "BW=" "$file" | grep write | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    bw_array_rw_read[$index]=",$bw_read"
    bw_array_rw_write[$index]=",$bw_write"
}

# Extract average IOPS from the data file created by running the test
# NOTE:
# - IOPS unity: second
# - If IOPS given in thousands (K) of IOPS, it will be multiplied by 1000.
select_iops_rw() 
{
    index=$1
    file=$2
    # iops_read=$(fgrep "IOPS=" "$file" | grep read | gawk -F[=,]+ '{print $2}')
    iops_read=$(grep "IOPS=" "$file" | grep read | gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1024)} else {print $2}}')
    # iops_write=$(fgrep "IOPS=" "$file" | grep write | gawk -F[=,]+ '{print $2}')
    iops_write=$(grep "IOPS=" "$file" |  grep write |gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1024)} else {print $2}}')
    iops_array_rw_read[$index]=",$iops_read"
    iops_array_rw_write[$index]=",$iops_write"
}

# Extract average latency from the data file created by running the test
# NOTE:
# - Latency unity: ms (millisecond). 
# - If Latency given in microsecond, it will convert to millisecond by dividing
#   by 1000.
select_lat_rw() 
{
    index=$1
    data_file=$2
    
    line=`grep "read" "$data_file" -A3 | grep "avg" | grep -v -E "clat|slat"`
    lat_read=`echo $line | gawk -F[=,:]+ '{if($1 == "lat (usec)") {printf("%.2f", $7/1000);} else {printf("%.2f", $7)} }'`
    line=`grep "write" "$data_file" -A3 | grep "avg" | grep -v -E "clat|slat"`
    lat_write=`echo $line | gawk -F[=,:]+ '{if($1 == "lat (usec)") {printf("%.2f", $7/1000);} else {printf("%.2f", $7)} }'`

    lat_array_rw_read[$index]=",$lat_read"
    lat_array_rw_write[$index]=",$lat_write"
}

# Generate the header for table in CSV format so it can be easily imported
# Header is written to $out_file
print_table_header()
{
    job_name=$1
    out_file=$2
    declare -a job_header=("${!3}")

    echo -n "[$job_name] " >> "$out_file"
    for (( i = 0; i < ${#job_header[@]}; ++i )) 
    do 
       echo -n ",${job_header[$i]}" >> "$out_file" 
    done
    echo >> "$out_file" 
}

main()
{
   # run all the jobs
   for job in "${JOBS[@]}"
   do
      # generate job file for current job
      for block_size in "${BLOCK_SIZES[@]}"
      do
         if [ "$job" != "randrw" ]; then
            echo "run $job in $block_size"
            gen_job_file $job $block_size
            run_test $job $block_size
         else
            # echo "run $job in ${BLOCK_SIZES[@]}"
            for rate in "${RWMIXREADS[@]}"
            do
                echo "run $job in $block_size, rwmixread=$rate"
                gen_job_file $job $block_size $rate
                run_test $job $block_size $rate
            done
         fi
      done
   done

   bw_array=()
   iops_array=()
   lat_array=()

   # use for test randrw
   bw_array_rw_read=()
   iops_array_rw_read=()
   lat_array_rw_read=()
   bw_array_rw_write=()
   iops_array_rw_write=()
   lat_array_rw_write=()


   # generate the test result table
   # output_file="$OUTDIR/$OUTDIR.result"
   output_file="$OUTDIR/$(basename $OUTDIR).result"
   echo > "$output_file"

   for job in "${JOBS[@]}"
   do
    
      if [ "$job" != "randrw" ]; then

	 print_table_header $job $output_file BLOCK_SIZES[@]

         for (( i = 0; i < ${#BLOCK_SIZES[@]}; ++i ))
         do
            block_size=${BLOCK_SIZES[$i]}
            
            log_file="$OUTDIR/fio.$job.$block_size.1.log"
            echo $log_file
            select_bw $i $log_file
            select_iops $i $log_file
            select_lat $i $log_file
         done
        
         echo "[bw (KB/S)] ${bw_array[@]}" >> $output_file
         echo "[lat (ms)] ${lat_array[@]}" >> $output_file
         echo "[iops] ${iops_array[@]}" >> $output_file
         echo >> $output_file
        
         # clear array
         bw_array=()
         iops_array=()
         lat_array=()
      else
        for rate in "${RWMIXREADS[@]}"
         do
            # echo "[$job"_"$rate] ${BLOCK_SIZES[@]}" >> "$output_file"
	    print_table_header "$job"_"$rate" $output_file BLOCK_SIZES[@]

            for (( i = 0; i < ${#BLOCK_SIZES[@]}; ++i ))
            do
                block_size=${BLOCK_SIZES[$i]}
            
                log_file="$OUTDIR/fio.$job.$block_size.$rate.1.log"
                echo $log_file
                select_bw_rw $i $log_file
                select_iops_rw $i $file
                select_lat_rw $i $log_file
            done

            echo "[bw_read (KB/S)] ${bw_array_rw_read[@]}" >> $output_file
            echo "[lat_read (ms)] ${lat_array_rw_read[@]}" >> $output_file
            echo "[iops_read] ${iops_array_rw_read[@]}" >> $output_file
            echo "[bw_write (KB/S)] ${bw_array_rw_write[@]}" >> $output_file
            echo "[lat_write (ms)] ${lat_array_rw_write[@]}" >> $output_file
            echo "[iops_write] ${iops_array_rw_write[@]}" >> $output_file
            echo >> $output_file
            
            # clear array
            bw_array_rw_read=()
            iops_array_rw_read=()
            lat_array_rw_read=()
            bw_array_rw_write=()
            iops_array_rw_write=()
            lat_array_rw_write=()

         done
        
      fi
   done

   cleanup
}

# Processing arguments
# NOTE:
# - For default values, see "Constants and default values" session above
#
if [ $# -lt 2 ]
then
   usage $0
else
   POSITIONAL=()
   while [[ $# -gt 0 ]]
   do
      key=$1

      case $key in
         -d|--device)
	    DEV=$2
	    shift
	    shift
	    ;;
         -o|--outdir)
            OUTDIR="$2"
            if [ ! -d $OUTDIR ]
	    then
                mkdir -p $OUTDIR
            fi
	    shift
	    shift
	    ;;
	 -i|--iodepth)
            IODEPTH=$2
	    shift
	    shift
	    ;;
	 -e|--ioengine)
            IOENGINE=$2
	    shift
	    shift
	    ;;
	 -m|--mixreads)
	    # Treat it as an array regardless
            read -a RWMIXREADS <<< $2
	    shift
	    shift
	    ;;
	 -s|--steadystate)
            SSTATETYPE=$2
            echo "Steady State Criteria = $SSTATETYPE"
	    shift
	    shift
	    ;;
	 *)
	    usage $0
	    ;;
      esac
   done
fi

echo "IO depth= $IODEPTH"

echo "IO Engine= $IOENGINE"
case $IOENGINE in
   "spdk" )
      IOENGINEPATH="$SPDKPATH/examples/nvme/fio_plugin/fio_plugin"
      RUNTEST="/usr/bin/env LD_PRELOAD=$IOENGINEPATH $FIO"
      ;;
   *)
      RUNTEST="$FIO" 
      IOENGINEPATH="$IOENGINE"
      ;;
esac

echo "RW Mixreads= (${RWMIXREADS[@]})"

main
