#!/bin/bash
# ./parse_all.sh <result_dir>
DIR=$1

echo "YCSB LevelDB Result: Throughput(ops/sec)" > temp_result.txt

for dir in $DIR/*; do
	dirname="$(basename $dir)"
    for file in $dir/*.out; do
	filename=$(basename $file)
	wkld=$(echo $filename | xargs | cut -d '_' -f 1)
	th_num=$(echo $filename | xargs | cut -d '_' -f 2 | cut -d '.' -f 1)
	tput=$(grep "Run throughput" $file | xargs | cut -d ' ' -f 3)
	echo "$wkld,$dirname,$th_num,$tput" >> temp_result.txt
    done
done


cat temp_result.txt | head -n 1
cat temp_result.txt | tail -n +2 | sort -t, -k1,1 -k2,2 -k3,3n
rm temp_result.txt
