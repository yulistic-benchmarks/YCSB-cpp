#!/bin/bash
# Set proper path of leveldb. You need to build leveldb first.
LEVELDB_PATH="/home/yulistic/oxbow/bench/leveldb"

git submodule update --init

make BIND_LEVELDB=1 EXTRA_CXXFLAGS=-I${LEVELDB_PATH}/include EXTRA_LDFLAGS="-L${LEVELDB_PATH}/build -lsnappy"
