#!/bin/bash

API_INIT="meocloud_init"
API_WORK="meocloud_upload"
API_END=""
API_FAIL=""


MEOCLOUD_CONF="/home/joao/meocloud/meocloud/meocloud.conf"
MEOCLOUD_BIN="/home/joao/meocloud/meocloud/meocloud"


meocloud_init() {

  if [ -f "$MEOCLOUD_CONF" -a -x "$MEOCLOUD_BIN" ]; then

    return 0
  fi

  log "Failed to init meocloud"
  return 1
}


meocloud_upload() {

  local $host
  local $week
  local $fname
  local $flocation
  local $CLOUD_LOC
  local $CLOUD_INDEX
  local $ret

  host="$(hostname)"
  week="$1"
  fname="$2"
  flocation="$3"

  CLOUD_LOC="/backup_${host}/${week}/${fname}"
  CLOUD_INDEX="/backup_${host}/backup.index.txt"
  

  log "Sending compressed file to MEOCLOUD"

  sync

  eval "$MEOCLOUD_BIN -c $MEOCLOUD_CONF -f $flocation -n $CLOUD_LOC -d" 2>&1 | log_r
  ret=$?

  if [ -f "$INDEX_FILE_OUTPUT" ]; then
    log "Sending backup index to MEOCLOUD"

    eval "$MEOCLOUD_BIN -c $MEOCLOUD_CONF -f $INDEX_FILE_OUTPUT -n $CLOUD_INDEX -y -d" 2>&1 | log_r
  fi
  

  return $ret
}

