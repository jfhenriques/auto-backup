#!/bin/bash


dir="/etc/abackup"
LOG_FILE="/var/log/abackup.log"
db="${dir}/db"
active="${dir}/.active"
pid="$$"

exit_success=0

GZIP_COMPRESSION="-9"
MAX_PIGZ_CPU=2

INCLUDE_LIST="${dir}/backup.list"
EXCLUDE_LIST="${dir}/exclude.list"
MAX_FILE_TRIES=1000
LAST_COUNT_FILE=".last_count"
LAST_MTIME_FILE="${dir}/.last_mtime"
INDEX_EXT=".index"
#DIR_OUTPUT="/mnt/gdrive"
DIR_OUTPUT="/tmp"

#GDRIVE api is currently broken for large files
#BACKUP_API="gdrive.api"
BASE_MOUNT_POINT="${dir}/.mpoint"


trap do_cleanup SIGHUP SIGINT SIGTERM

###############################################################################
# Utilities
###############################################################################

s_rm() {
  rm -f "$1" >/dev/null 2>&1
}
do_cleanup() {
  log "Cleaning up"
  s_rm "$active"

  [ "$db_file_t" != "" ] && [ -f "$db_file_t" ] && s_rm "$db_file_t"

  if [ $exit_success -eq 0 ]; then
    [ "$output_file_gz" != "" ] && [ -f "$output_file_gz" ] && s_rm "$output_file_gz"
    [ "$db_file" != "" ] && [ -f "$db_file" ] && s_rm "$db_file"
  fi

  [ "$API_END" != "" ] && "$API_END"


  if [ "$1" = "" ]; then
    exit 0
  else
    exit "$1"
  fi
}

stamp() {
  echo $(date +"%Y-%m-%d %T.%3N")
}
get_dbdate() {
  echo "$(date +"%Y%m%d")"
}
get_dbfulldate() {
  echo "$(date +"%Y%m%d%H%M%S")"
}

get_ym() {
  echo "$(date +"%Y%m")"
}

log() {
  stamp=$(stamp)

  echo "[${stamp}] $1" | tee -a "$LOG_FILE" 2>/dev/null
}

s_mkdir() {
  mkdir -p "$1" > /dev/null 2>&1
}

get_gzip() {
  if pigz -V 2>/dev/null; then
    echo "pigz -p ${MAX_PIGZ_CPU} ${GZIP_COMPRESSION}"
  else
    echo "gzip ${GZIP_COMPRESSION}"
  fi
}

rand_mt () {
 < /dev/urandom tr -dc A-Za-z0-9 | head -c${1:-16};echo;
}

gen_rand_mp() {
  echo "${BASE_MOUNT_POINT}/$(rand_mt)"
}

gen_mount_point() {

  local _GD_MPOINT="$(gen_rand_mp)"

  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"


  echo "$_GD_MPOINT"
}


###############################################################################
# Start
###############################################################################

s_mkdir "$db"
s_mkdir "$DIR_OUTPUT"

GZIP=$(get_gzip)

log "Starting a new backup"

if [[ $EUID -ne 0 ]]; then
  log "Error - This script must be run as root"

  exit 1
fi

if [ -f "$active" ]; then
  log "Error - An automated backup is still running"

  exit 1
fi

if [ ! -s "$INCLUDE_LIST" ]; then
  log "Error - File list '$INCLUDE_LIST' does not exist or is empty!"

  exit 1
fi 

echo "$pid" > "$active"

# init API

if [ "$BACKUP_API" != "" ]; then

  API_MOUNT_POINT="$(gen_mount_point)"

  if [ "$API_MOUNT_POINT" != "" ]; then

    . "$BACKUP_API"

    [ "$API_INIT" != "" ] && "$API_INIT"

    if [ $? -eq 0 ] && [ "$API_GET_MOUNT_POINT" != "" ]; then

      DIR_OUTPUT="$($API_GET_MOUNT_POINT)"
    else

      log "Error initializing remote backup API"
      BACKUP_API=""
    fi
  fi
fi


arg1=$(echo "$1" | awk '{print tolower($0)}')

[ -f "$LAST_MTIME_FILE" ] && \
last_b_time=$(cat "$LAST_MTIME_FILE" | xargs -0 date --utc --date 2>/dev/null)

if [ "$arg1" = "full" ] || [ "$last_b_time" = "" ] ; then
  last_b_time="Thu Jan  1 00:00:00 UTC 1970"

  log "Entering full backup mode"
  full_backup="_full"
else
  log "Entering incremental mode (Files modified after: '${last_b_time}')"
fi

db_date="$(get_dbfulldate)"
db_dir="${db}/$(get_dbdate)"
db_dir_last="${db_dir}/${LAST_COUNT_FILE}"
db_possible=0

if [ -s "$db_dir_last" ]; then
  db_count=$(cat "$db_dir_last")
  if [ $db_count -eq $db_count -a $db_count -gt 0 2>/dev/null ]; then
    db_count=$(expr "$db_count" + 1)
  else
    db_count=1
  fi
else
  db_count=1
fi

#log "Backup directory is: '${db_dir}'"
s_mkdir "$db_dir"

for ((i=db_count; i<=MAX_FILE_TRIES; i++)); do

  db_file_c=$(printf "%04d" "$i")
  db_file="${db_dir}/${db_file_c}${INDEX_EXT}"

  if [ ! -f "$db_file" ]; then
    db_possible=1
    echo "$i" > "$db_dir_last"
    break
  fi

done

if [[ "$db_possible" -eq 0 ]]; then
  log "Error - Maximum of ${MAX_FILE_TRIES} backups per day reached"
  do_cleanup 1
fi

db_file_t="${db_dir}/${db_file_c}.tmp"
log "Writing file index: '${db_file}'"


[ -f "$EXCLUDE_LIST" ] && \
exclude_files=$(cat "$EXCLUDE_LIST" | \
    while read f; do
      if [ "$f" = "" ]; then continue; fi
      echo -ne " ! -ipath \"${f}/*\""
    done)

SEARCH_STARTED=$(date --utc)

while read f; do
  if [ "$f" = "" ]; then continue; fi

  command="find \"$f\" -newermt \"${last_b_time}\" -type f $exclude_files ! -ipath \"${BASE_MOUNT_POINT}/*\" "

  eval "$command" 2>/dev/null

done < "$INCLUDE_LIST" > "$db_file_t"

log "Trying to remove duplicates..."

awk '!a[$0]++' "$db_file_t" > "$db_file" 2>/dev/null

s_rm "$db_file_t"

if [ -s "$db_file" ]; then

  output_file_gz="${DIR_OUTPUT}/${db_date}_${db_file_c}${full_backup}.tgz"

  log "Creating backup file: '${output_file_gz}'"

  tar --ignore-failed-read -c -T "$db_file" 2>/dev/null | $GZIP > "$output_file_gz"
  ret_code=$?

  if [ $ret_code -ne 0 ]; then
    log "Error using tar to compress file"
    
    do_cleanup 1
  fi
else
  log "No files to backup"
fi

exit_success=1
echo "$SEARCH_STARTED" > "$LAST_MTIME_FILE"
log "Terminating naturally"

do_cleanup

