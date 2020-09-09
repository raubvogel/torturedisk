#!/bin/bash

##
# Torturedisk
#
# Wrapper to automate disk (and disk like beings) performance testing
#
# AUTHOR: raubvogel@gmail.com
#
# RELEASE: 0.3.1.
# 0.3.1.
# - Submit multiple devices as input, which will then be tested in
#   sequence using the same parameters
# 0.3.0.
# - Pass the output dir as argument since we are creating it at main()
#   for each device we will be running the test on.
# - Solved why the randomrw tests are not being properly written to logs
# 0.2.3.
# - We have now a default OUTDIR which is based on date+time so we can
#   make multiple *sequential* runs while without entering OUTDIR.
# 0.2.2. 
# - Get spdk+perf partially working. Still does not work with rw
# - 1K seconds = 1000 seconds, not 1024 seconds
# - Make select_lat(), select_bw(), select_ipos() aware of spdk+perf
# - Convert time from min and hours to seconds for spdk+perf
# 0.2.1. Redo help page
# 0.2.0. Add fio+spdk support
# 0.1.0. Initial release
#
# REQUIREMENTS:
# - If running fio with libiaio
#   - You can use the fio package for your OS if available
#   - OR, you can compile fio (https://github.com/axboe/fio) yourself
#
# - If running spdk+fio,
#   1. Download spdk (https://github.com/spdk/spdk) and build it. 
#      Note you will also need to compile fio (https://github.com/axboe/fio)
#   2. Find the PCI path for the NVMe hard drive you want to test
#   3. Run this script providing the path to where you built spdk 
# 0.2.3. Some of the randrw tests are not being run. 
#        (https://github.com/raubvogel/torturedisk/issues/1)
#
# NOTE:
#
# TO DO:
# - Cut down on using globals unless absolutely needed. This is not Sinclair BASIC
# - Ensure variables are not named after bash commands
#

usage()
{
   program_name=$1

cat << EOF
$program_name: Run a set of disk performance tests and save the results
in a .csv-formatted file.

Usage: $program_name -d "dev" -o outdir [-i iodepth] [-e ioengine]"

Where:

   -d/--device: list of devices $program_name will be run on. 
     If ioengine=spdk*, device is the PCI "name" of NVMe device
     Ex: 
       -d "0000:63:00.0"
     A list of one is still a list
     All devices need to be of the same "type" (/dev/ vs PCI addresses)
     Listing the devices in quotes is specially important when there are more
      than one device.
   -o/--outdir: Name of the directory to save all the logs and the summary
     file. 
     Summary filename is "$outdir.result" inside the directory $outdir.
   -b|--blocksize: Block size
     Default: "512 4K 8K 16K 64K 128K 256K 512K"
   -e/--ioengine: IO engine. 
     Accepted values: libaio, spdk, spdk+perf
     Default is libaio.
   -i/--iodepth: IO Depth. Default is 8
   -j|--jobs: Tests to be performed
     Default is EVERYone (write randwrite read randread randrw)
       read: sequential read
       write: sequential write
       randread: random read
       randwrite: random write
   -m|--mixreads: % Rate between reads and writes
     If you want to enter and array enter it in quotes: "100 70 50 25 30"
     Default: "70 50 30"
     100 : 100% read 0% writes (read only)
       0 : 0% reads 100% writes (write only)
   -s/--steadystate: Run test either for 24h or until achieving steady state.
   -t|--time: Run time. 1 = 1s, 3m = 3min, 2h = 2 hours.
     Default: 30s
 
Arguments can be given in any order provided they have their required flags.
dev and outdir are required.

EOF
    exit 1
}

########################################################################
# Constants and default values
########################################################################
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

# The default rwmixreads for randrw
RWMIXREADS=(70 50 30)

########################################################################
# Functions
########################################################################

#==============================================================
#==============================================================
gen_job_file() 
{
    # gen_job_file job block_size [rwmixread]
    # gen_job_file $job_name $block_size $conf_file $device $job_rate
    job_name=$1
    block_size=$2
    conf_file=$3
    device=$4
    if [ $# -ge 5 ]; then
       job_rate=$5
    fi

    if [ $IOENGINE == "spdk+perf" ]
    then
       # spdk+perf can't do "K"s in block size
       # runtime in seconds
       cat > $conf_file << EOF
-o $(echo $block_size | gawk '{if(match($1, /[0-9]*[Kk]/)) {printf("%d", int($1)*1024)} else {printf("%d", int($1))}}')
-w $job_name 
-t $(echo $RUNTIME | gawk '{if(match($1, /[0-9]*[hH]/)) {printf("%d", int($1)*3600)} else if(match($1, /[0-9]*[mM]/)) {printf("%d", int($1)*60)} else {printf("%d", int($1))}}')
-q $IODEPTH 
-r 'trtype:PCIe traddr:$device' 
EOF
       if [ "$job_name" == "randrw" ]; then
           echo "-M $RWMIXREADS" >> $conf_file
       fi
    else
       # fio-specific config
       cat > $conf_file << EOF
[global]
bs=$block_size
direct=1
rw=$job_name
ioengine=$IOENGINEPATH
iodepth=$IODEPTH
EOF

       if [ -z ${SSTATETYPE+x} ]
       then
          echo "runtime=$RUNTIME" >> $conf_file
       else
          echo "runtime=24h" >> $conf_file
          echo "steadystate_duration=1800" >> $conf_file
          echo "steadystate=iops_slope:0.3%" >> $conf_file
       fi

       if [ "$job_name" == "randwrite_name" -o "$job_name" == "randread_name" -o "$job_name" == "randrw" ]; then
           echo "randrepeat=0" >> $conf_file
       fi

       echo "" >> $conf_file
       echo "[test]" >> $conf_file
       if [ "$job_name" == "randrw" ]; then
           echo "rwmixread=$job_rate" >> $conf_file
       fi

       if [ "$IOENGINE" == "spdk" ]; then
           echo 'thread=1' >> $conf_file
           echo "filename=trtype=PCIe traddr=$(echo $device|tr \: \.) ns=1" >> $conf_file
       else
	   # Default: fio+libaio
           echo "filename=$device" >> $conf_file
       fi
    fi
}

#==============================================================
#==============================================================
cleanup() 
{
    outdir=$1

    for job in "${JOBS[@]}"
    do
        rm -f $outdir/$job
    done
    rm -f *.tmp
}

#==============================================================
#==============================================================
run_test() 
{
    # run_test $confile $outfile 
    conf_file=$1
    outfile=$2

    if [ $IOENGINE == "spdk+perf" ]
    then
       # echo "xargs -a $conf_file $RUNTEST > $outfile"
       xargs -a $conf_file $RUNTEST > $outfile
    else
       $RUNTEST $conf_file --output="$outfile"
    fi

}

#==============================================================
# unit:KiB/S
#==============================================================
select_bw() 
{
    index=$1
    data_file=$2

    if [ $IOENGINE == "spdk+perf" ]
    then
       # spdk+perf uses MiB/s
       bw=$(echo "$(sed -n '/^Total/p' "$data_file" | tr -s '[:space:]' | \
       cut -d : -f 2 | cut -d ' ' -f 3 )*1024" | bc) 
    else
       bw=$(fgrep "BW=" "$data_file" | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    fi
    bw_array[$index]=",$bw"
}

#==============================================================
# unit: S
#==============================================================
select_iops() 
{
    index=$1
    data_file=$2

    if [ $IOENGINE == "spdk+perf" ]
    then
       iops=$(sed -n '/^Total/p' "$data_file" | tr -s '[:space:]' | \
       cut -d : -f 2 | cut -d ' ' -f 2 ) 
    else
       iops=$(grep "IOPS=" "$data_file" | gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1024)} else {print $2}}')
    fi
    iops_array[$index]=",$iops"
}

#==============================================================
# unit:ms
#==============================================================
select_lat() 
{
    index=$1
    file=$2

    if [ $IOENGINE == "spdk+perf" ]
    then
       # spdk+perf uses uS
       # We are picking average, not min or max
       lat=$(echo "$(sed -n '/^Total/p' "$data_file" | tr -s '[:space:]' | \
       cut -d : -f 2 | cut -d ' ' -f 4 )*1000" | bc) 
    else
       line=`grep "lat" "$file" | grep "avg" | grep -v -E "clat|slat"`
       lat=`echo $line | gawk -F[=,:]+ '{if($1 == "lat (usec)") {printf("%.2f", $7/1000);} else {printf("%.2f", $7)} }'`
    fi
    lat_array[$index]=",$lat"
}

#==============================================================
# unit:KB/S
#==============================================================
select_bw_rw() 
{
    index=$1
    file=$2
    bw_read=$(fgrep "BW=" "$file" | grep read | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    bw_write=$(fgrep "BW=" "$file" | grep write | gawk -F[=,]+ '{if(match($4, /[0-9]*[Kk]/)) {printf("%d", $4)} else {printf("%d", int($4)*1024)}}')
    bw_array_rw_read[$index]=",$bw_read"
    bw_array_rw_write[$index]=",$bw_write"
}

#==============================================================
# Extract average IOPS from the data file created by running the test
# NOTE:
# - IOPS unity: second
# - If IOPS given in thousands (K) of seconds, it will be multiplied by 1000.
#==============================================================
select_iops_rw() 
{
    index=$1
    file=$2
    iops_read=$(grep "IOPS=" "$file" | grep read | gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1000)} else {print $2}}')
    iops_write=$(grep "IOPS=" "$file" |  grep write |gawk -F[=,]+ '{if(match($2, /[0-9]*[Kk]/)) {printf("%d", int($2)*1000)} else {print $2}}')
    iops_array_rw_read[$index]=",$iops_read"
    iops_array_rw_write[$index]=",$iops_write"
}

#==============================================================
# Extract average latency from the data file created by running the test
# NOTE:
# - Latency unity: ms (millisecond). 
# - If Latency given in microsecond, it will convert to millisecond by dividing
#   by 1000.
#==============================================================
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

#==============================================================
# Run all the jobs
# 
# Input:
# - device 
# - out_dir
#==============================================================
run_all_jobs()
{
   device_name=$1
   out_dir=$2
   # run all the jobs
   for job_name in "${JOBS[@]}"
   do
      # generate job file for current job
      for block_size in "${BLOCK_SIZES[@]}"
      do
         if [ "$job_name" != "randrw" ]; then
            confile="$out_dir/torture.$job_name.$block_size.1"
            outfile="$confile.log"
            echo "run $job_name with $block_size on $device_name"
            gen_job_file $job_name $block_size $confile $device_name
            run_test $confile $outfile 
         else
            # echo "run $job_name in ${BLOCK_SIZES[@]}"
            for job_rate in "${RWMIXREADS[@]}"
            do
                confile="$out_dir/torture.$job_name.$block_size.$job_rate.1"
                outfile="$confile.log"
                echo "run $job_name with $block_size, rwmixread=$job_rate on $device_name"
                gen_job_file $job_name $block_size $confile $device_name $job_rate
                run_test $confile $outfile 
            done
         fi
      done
   done
}

#==============================================================
# $device $out_dir
# out_dir     : Directory where logs will be stored
# JOBS        : 
# BLOCK_SIZES : Block size used for 
# RWMIXREADS  : Ratio between reads and writes. 70 = 70 read/30 write
#==============================================================
echo "create_output_file()"
create_output_file()
{

   # Initialize arrays
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
   output_file="$out_dir/$(basename $out_dir).result"
   echo > "$output_file"

   for job in "${JOBS[@]}"
   do
    
      if [ "$job" != "randrw" ]
      then

	 print_table_header $job $output_file BLOCK_SIZES[@]

         for (( i = 0; i < ${#BLOCK_SIZES[@]}; ++i ))
         do
            block_size=${BLOCK_SIZES[$i]}
            
            log_file="$out_dir/torture.$job.$block_size.1.log"
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
      # spedk+perf current not able to do randrw
      else
        for rate in "${RWMIXREADS[@]}"
         do
            # echo "[$job"_"$rate] ${BLOCK_SIZES[@]}" >> "$output_file"
	    print_table_header "$job"_"$rate" $output_file BLOCK_SIZES[@]

            for (( i = 0; i < ${#BLOCK_SIZES[@]}; ++i ))
            do
                block_size=${BLOCK_SIZES[$i]}
            
                log_file="$out_dir/torture.$job.$block_size.$rate.1.log"
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
}

main()
{

   # run all the jobs in all devices
   # We will loop over all entries in $DEV
   # run_all_jobs
   for device in "${DEV[@]}"
   do
      if [ -z "$OUTDIR" ]
      then
         # Default name for resultdir is based on the IOENGINE and $device
         resultdir="$(basename $device)-$IOENGINE"_$(date +%F-%H%M)
      else
         # If you have $OUTDIR, resultdir is based on it and $device
         resultdir="$(basename $device)-$OUTDIR"_$(date +%F-%H%M)
      fi
      mkdir $resultdir

      # rm -f $resultdir/$job
      run_all_jobs $device $resultdir

      # Process the logs
      create_output_file $device $resultdir

      cleanup $resultdir
   done
}

########################################################################
# Processing command line arguments
# NOTE:
# - For default values, see "Constants and default values" session above
#
########################################################################
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
	    # Treat it as an array regardless
            read -a DEV <<< $2
	    shift
	    shift
	    ;;
	 -i|--iodepth)
            IODEPTH=$2
	    shift
	    shift
	    ;;
	 -b|--blocksize)
	    # Treat it as an array regardless
            read -a BLOCK_SIZES <<< $2
	    shift
	    shift
	    ;;
	 -j|--jobs)
	    # Treat it as an array regardless
            read -a JOBS <<< $2
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
         -o|--outdir)
            OUTDIR="$2"
            if [ ! -d $OUTDIR ]
	    then
                mkdir -p $OUTDIR
            fi
	    shift
	    shift
	    ;;
	 -s|--steadystate)
            SSTATETYPE=$2
            echo "Steady State Criteria = $SSTATETYPE"
	    shift
	    shift
	    ;;
	 -t|--time)
            RUNTIME=$2
	    shift
	    shift
	    ;;
	 *)
	    usage $0
	    ;;
      esac
   done
fi

# Bailout if device was not entered

echo "Tests to be performed = (${JOBS[@]})"
echo "Max runtime per test: $RUNTIME"
echo "IO depth= $IODEPTH"

echo "IO Engine= $IOENGINE"
case $IOENGINE in
   "spdk"|"fio+spdk" )
      IOENGINEPATH="$SPDKPATH/examples/nvme/fio_plugin/fio_plugin"
      RUNTEST="/usr/bin/env LD_PRELOAD=$IOENGINEPATH $FIO"
      ;;
   "spdk+perf" )
      # IOENGINEPATH="$SPDKPATH/examples/nvme/perf/perf"
      RUNTEST="$SPDKPATH/examples/nvme/perf/perf"
      ;;
   *)
      RUNTEST="$FIO" 
      IOENGINEPATH="$IOENGINE"
      ;;
esac

echo "Read/Write ratios to be run = (${RWMIXREADS[@]})"

main
