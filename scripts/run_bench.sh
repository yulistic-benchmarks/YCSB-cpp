#! /usr/bin/sudo /bin/bash
#
# Run it in the project root. I.e., scripts/run_ycsb.sh
#
set -e
print_usage() {
	echo "Usage: $0 [ -t ext4|oxbow ] [ -c ] [ -j journal|ordered ] [ -l ]"
	echo "	-t : System type. <ext4|oxbow> (ext4 is default)"
	echo "	-c : Measure CPU utilization."
	echo "	-j : Ext4 journal mode. <journal|ordered>"
	echo "	-l : Do load db (need once)."
}

drop_caches() {
	sync
	sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
}

initOxbow() {
	# Runninng Daemon as background
	$SECURE_DAEMON/run.sh -b
	sleep 10
	DAEMON_PID=$(pgrep "secure_daemon")
	echo "[OXBOW_MICROBENCH] Daemon runnning PID: $DAEMON_PID"

	sudo mount -t illufs dummy $OXBOW_PREFIX
	echo "[OXBOW_MICROBENCH] mount oxbow FS\n"
	sleep 5
}

killBgOxbow() {
	# Kill Daemon
	echo "[OXBOW_MICROBENCH] Kill secure daemon($DAEMON_PID) and umount Oxbow."
	$SECURE_DAEMON/run.sh -k
	sleep 5

	# sudo kill -9 $DAEMON_PID
	# echo "[OXBOW_MICROBENCH] Exit secure daemon $DAEMON_PID"
	# sleep 5

	# sudo umount $OXBOW_PREFIX
	# echo "[OXBOW_MICROBENCH] umount oxbow FS\n"
	# sleep 5

}

restart_ox_daemon() {
	killBgOxbow
	initOxbow
}

dumpOxbowConfig() {
	if [ -e "${LIBFS}/myconf.sh" ]; then
		echo "$LIBFS/myconf.sh:" >${OUT_FILE}.fsconf
		cat $LIBFS/libfs_conf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$LIBFS/libfs_conf.sh:" >>${OUT_FILE}.fsconf
	cat $LIBFS/libfs_conf.sh >>${OUT_FILE}.fsconf

	if [ -e "${SECURE_DAEMON}/myconf.sh" ]; then
		echo "$SECURE_DAEMON/myconf.sh" >>${OUT_FILE}.fsconf
		cat $SECURE_DAEMON/myconf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$SECURE_DAEMON/secure_daemon_conf.sh:" >>${OUT_FILE}.fsconf
	cat $SECURE_DAEMON/secure_daemon_conf.sh >>${OUT_FILE}.fsconf

	if [ -e "${DEVFS}/myconf.sh" ]; then
		echo "$DEVFS/myconf.sh" >>${OUT_FILE}.fsconf
		cat $DEVFS/myconf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$DEVFS/devfs_conf.sh:" >>${OUT_FILE}.fsconf
	cat $DEVFS/devfs_conf.sh >>${OUT_FILE}.fsconf
}


# Send remote checkpoint signal to DevFS.
checkpoint() {
	sig_nu=$(expr $(kill -l SIGRTMIN) + 1)
	cmd="sudo pkill -${sig_nu} devfs"
	ssh ${DEVICE_IP} $cmd
}

run_ycsb() {
	load_done=$LOAD_DONE

	# The order of workloads matters. Read workloads should be after a write workload.
	for WL in $WORKLOADS; do
		for TH in $THREADS; do
			echo "Run LevelDB with YCSB workload${WL}."
			output_file="./${OUTPUT_DIR}/${WL}_${TH}"

			if [ "$CPU_UTIL" = "1" ]; then
				OUT_CPU_FILE=${output_file}.perfdata
				PERF_PREFIX="sudo $PERF_BIN record -F 99 -e cycles -a -o $OUT_CPU_FILE --"
			else
				PERF_PREFIX=""
			fi


			#  -p fieldcount=1 -p fieldlength=66: to set the size of data to be 80B (uFS configuration).
			YCSB_LOAD_CMD="ycsb -load -db leveldb -P workloads/workload${WL} -P leveldb/myleveldb.properties -p threadcount=8 -p recordcount=10000000 -s -p fieldcount=1 -p fieldlength=66"
			YCSB_CMD="ycsb -run -db leveldb -P workloads/workload${WL} -P leveldb/myleveldb.properties -p threadcount=${TH} -p operationcount=100000 -s -p fieldcount=1 -p fieldlength=66"

			if [ "$SYSTEM" == "oxbow" ]; then
				if [ "$load_done" -eq "0" ];then
					# Load
					CMD="${LIBFS}/run.sh ${BENCH_YCSBCC}/${YCSB_LOAD_CMD} 2>&1 | tee -a ${output_file}.out"
					echo Load command: "$CMD" | tee ${output_file}.out
					eval $CMD # Execute.
					load_done=1
				fi

				restart_ox_daemon

				# Run
				CMD="$PERF_PREFIX '${LIBFS}/run.sh ${BENCH_YCSBCC}/${YCSB_CMD} 2>&1 | tee -a ${output_file}.out'"
				echo Run command: "$CMD" | tee -a ${output_file}.out
				eval $CMD # Execute.

			elif [ "$SYSTEM" == "ext4" ]; then
				if [ "$load_done" -eq "0" ];then
					# Load
					CMD="sudo $PINNING ./${YCSB_LOAD_CMD} 2>&1 | tee -a ${output_file}.out"
					echo Load command: "$CMD" | tee ${output_file}.out
					eval $CMD # Execute.
					load_done=1
				fi

				drop_caches

				# Run
				CMD="$PERF_PREFIX sudo $PINNING ./${YCSB_CMD} 2>&1 | tee -a ${output_file}.out"
				echo Run command: "$CMD" | tee -a ${output_file}.out
				eval $CMD # Execute.
			fi
		done
		sleep 1
	done
}

umountExt4() {
	sudo umount $MOUNT_PATH || true
}

###########################################################################

# Default configurations.
SYSTEM="ext4"
DIR="./tempdir"
CPU_UTIL=0
EXT4_JOURNAL_MODE="journal"
WORKLOADS="a b c d e f"
THREADS="1 2 4 8 16"
LOAD_DONE=1 # Set to 0 to do load.

while getopts "ct:j:l?h" opt; do
	case $opt in
	c)
		CPU_UTIL=1
		;;
	t)
		SYSTEM=$OPTARG
		if [ "$SYSTEM" != "ext4" ] && [ "$SYSTEM" != "oxbow" ]; then
			print_usage
			exit 2
		fi
		;;
	j)
		EXT4_JOURNAL_MODE=$OPTARG
		;;
	l)
		LOAD_DONE=0
		;;
	h | ?)
		print_usage
		exit 2
		;;
	esac
done

if [ "$SYSTEM" == "oxbow" ] && [ -z "$OXBOW_ENV_SOURCED" ]; then
	echo "Do source oxbow/set_env.sh first."
	exit
fi

OUTPUT_DIR="results_leveldb/${SYSTEM}_${EXT4_JOURNAL_MODE}"
PERF_BIN="/lib/modules/$(uname -r)/source/tools/perf/perf" # Set correct perf bin path.

echo "------ Configurations -------"
echo "SYSTEM     : $SYSTEM"
echo "CPU_UTIL   : $CPU_UTIL"
echo "OUTPUT_DIR : $OUTPUT_DIR"
echo "-----------------------------"

# Check perf bin.
if [ "$CPU_UTIL" = "1" ]; then
	$PERF_BIN -h &>/dev/null || { echo "Set proper perf bin. Current setup: ${PERF_BIN}"; exit 1; }
fi

mkdir -p "$OUTPUT_DIR"

# Kill all the existing leveldb processes.
sudo pkill -9 ycsb || true

# Mount.
if [ $SYSTEM == "ext4" ]; then
	MOUNT_PATH="/mnt/ext4"
	DIR="$MOUNT_PATH/ext4_${EXT4_JOURNAL_MODE}"
	INODE_NUM=6104832 # To reduce mkfs time. Set proper value.
	PINNING="numactl -N1 -m1"
	NUMA="1"
	CPU_MASK="16-31"

	# Set nvme device path.
	# DEV_PATH="/dev/nvme2n1"
	#
	# Or, get it automatically. nvme-cli is required. (sudo apt install nvme-cli)
	DEV_PATH="$(sudo nvme list | grep "SAMSUNG MZPLJ3T2HBJR-00007" | xargs | cut -d " " -f 1)"
	echo Device path: "$DEV_PATH"

	# Set total journal size.
	# TOTAL_JOURNAL_SIZE=5120 # 5 GB
	TOTAL_JOURNAL_SIZE=$((38 * 1024)) # 38 GB

	# Set workload path.
	sed -i "/leveldb.dbname=*/c\leveldb.dbname=${DIR}" leveldb/myleveldb.properties

	umountExt4

	if [ "$LOAD_DONE" -eq "0" ];then
		sudo mke2fs -t ext4 -J size=$TOTAL_JOURNAL_SIZE -E lazy_itable_init=0,lazy_journal_init=0 -N $INODE_NUM -F -G 1 $DEV_PATH
	fi
	sudo mount -t ext4 -o barrier=0,data=$EXT4_JOURNAL_MODE $DEV_PATH $MOUNT_PATH
	sudo chown -R $USER:$USER $MOUNT_PATH
	mkdir -p $DIR

	# NUMA binding:
	jbd_pid=$(ps aux | grep jbd2 | grep $(basename $DEV_PATH) | xargs | cut -d ' ' -f2)
	sudo taskset -cp $CPU_MASK $jbd_pid
	echo "Binding jbd2 process($jbd_pid) to NUMA ${NUMA}. Taskset result:" 2>&1 | tee ./${OUTPUT_DIR}/fsconf
	sudo taskset -p $jbd_pid 2>&1 | tee -a ./${OUTPUT_DIR}/fsconf

	# Dump config.
	sudo dumpe2fs -h $DEV_PATH >> ./${OUTPUT_DIR}/fsconf

elif [ $SYSTEM == "oxbow" ]; then
	DIR="$OXBOW_PREFIX"

	# Set workload path.
	sed -i "/leveldb.dbname=*/c\leveldb.dbname=${DIR}" leveldb/myleveldb.properties

	# Umount if mounted.
	sudo umount $OXBOW_PREFIX || true

	# Kill all the Oxbow processes.
	$SECURE_DAEMON/run.sh -k || true
	sleep 3

	initOxbow

	sudo chown -R $USER:$USER $MOUNT_PATH
	# mkdir -p $DIRS # Use root directory.
fi

# Run leveldb bench.
run_ycsb

# Kill and unmount.
if [ $SYSTEM == "ext4" ]; then
	sudo umount $MOUNT_PATH || true

elif [ $SYSTEM == "oxbow" ]; then
	killBgOxbow
fi

# Parse results.
scripts/parse_results.sh $OUTPUT_DIR
