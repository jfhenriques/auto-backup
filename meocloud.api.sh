#!/bin/bash

# Source code for meocloud command line application at:
# https://github.com/jfhenriques/meocloud-upload

API_INIT="meocloud_init"
API_WORK="meocloud_upload"
API_END=""


MEOCLOUD_CONF="/etc/meocloud.conf"
MEOCLOUD_BIN="/usr/bin/meocloud"


meocloud_init() {

  [ -f "$MEOCLOUD_CONF" ] && [ -x "$MEOCLOUD_BIN" ] && return 0

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

  eval "$USE_NICE $MEOCLOUD_BIN -c \"$MEOCLOUD_CONF\" -f \"$flocation\" -n \"$CLOUD_LOC\" -d" 2>&1 | log
  ret=$?

  if [ -f "$INDEX_FILE_OUTPUT" ]; then
    log "Sending backup index to MEOCLOUD"

    eval "$USE_NICE $MEOCLOUD_BIN -c \"$MEOCLOUD_CONF\" -f \"$INDEX_FILE_OUTPUT\" -n \"$CLOUD_INDEX\" -y -d" 2>&1 | log
  fi

  return $ret
}

