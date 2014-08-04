#!/bin/bash


dir="/mnt/backup/abackup"
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
WEEK_DIR=$(date +"%Y%W")
DIR_OUTPUT="/mnt/backup/store"
INDEX_FILE_OUTPUT="${DIR_OUTPUT}/backup.index"
DIR_OUTPUT="${DIR_OUTPUT}/${WEEK_DIR}"
#DIR_OUTPUT="/mnt/gdrive"

#GDRIVE api is currently broken for large files
#BACKUP_API="gdrive.api"
BASE_MOUNT_POINT="${dir}/.mpoint"

# Fill and uncomment EMAIL_RECIPIENTS and EMAIL_FROM to enable sending an email with a report
EMAIL_RECIPIENTS="email@example.com"
EMAIL_FROM="root@$(hostname)"

trap do_cleanup_signal SIGHUP SIGINT SIGTERM

###############################################################################
# Utilities
###############################################################################

LOG_BUFFER=""

s_rm() {
  rm -f "$1" >/dev/null 2>&1
}

email_report() {
  local $subject
  local $content
  local $date
  date=$(date --date "$SEARCH_STARTED" 2>/dev/null)
  
  if [ "$EMAIL_RECIPIENTS" != "" ]; then

    if [ $exit_success -eq 0 ]; then
       subject="[ABACKUP] FAILED - Started on: ${date}"
    else
       subject="[ABACKUP] SUCCESS - Started on: ${date}"
    fi

    content=$(echo -e "$LOG_BUFFER")

    /usr/sbin/sendmail -f "$EMAIL_FROM"  "$EMAIL_RECIPIENTS" << EOF
From: "Automated Backup" <${EMAIL_FROM}>
To: $EMAIL_RECIPIENTS
Subject: $subject

Hostname: $(hostname)

Log:
$content

EOF

    log "Report mail sent"
  fi

}

do_cleanup_signal() {
  log "Received kill signal"
  do_cleanup
}

do_cleanup() {
  log "Cleaning up"
  s_rm "$active"

  [ "$db_file_t" != "" ] && [ -f "$db_file_t" ] && s_rm "$db_file_t"

  if [ $exit_success -eq 0 ]; then
    [ "$output_file_gz" != "" ] && [ -f "$output_file_gz" ] && s_rm "$output_file_gz"
    [ "$db_file" != "" ] && [ -f "$db_file" ] && s_rm "$db_file"
  fi

  [ "$API_END" != "" ] && "$API_END" "$exit_success"

  email_report

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

  local msg="[${stamp}] $1"
  LOG_BUFFER="${LOG_BUFFER}\n${msg}"

  echo "$msg" | tee -a "$LOG_FILE" 2>/dev/null
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

get_pv() {
  if pv -V >/dev/null 2>&1; then
    echo "pv -s $1 |"
  else
    echo ""
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

get_backup_size() {

  if [ "$1" = "" ] || [ ! -f "$1" ]; then
    echo 0
  else
    echo $(cat "$1" |xargs -d \\n stat -c '%s' 2>/dev/null | awk '{total+=$1} END {print total}' 2>/dev/null)
  fi
}

get_human_read_size() {
  if [ "$1" = "" ]; then
    echo "0 B"
  else
    echo $(awk -v sum=$1 'BEGIN{
        hum[1024**3]="Gb";hum[1024**2]="Mb";hum[1024]="Kb";
        for (x=1024**3; x>=1024; x/=1024){
          if (sum>=x) { printf "%.2f %s\n",sum/x,hum[x];break }
        }}')

  fi
}



###############################################################################
# Start
###############################################################################


GZIP=$(get_gzip)

log "Starting a new backup"

#do_cleanup 1

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

s_mkdir "$db"
s_mkdir "$DIR_OUTPUT"

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
arg2=$(echo "$2" | awk '{print tolower($0)}')

if [ "$arg1" = "" ]; then
  arg1="inc"
fi

if [ "$arg2" = "" ]; then
  arg2="yes"
fi


[ -f "$LAST_MTIME_FILE" ] && \
last_b_time=$(cat "$LAST_MTIME_FILE" | xargs -0 date --utc --date 2>/dev/null)

if [ "$arg1" = "full" ] || [ "$last_b_time" = "" ] ; then
  last_b_time="Thu Jan  1 00:00:00 UTC 1970"
  arg1="full"

  log "Entering full backup mode"
  full_backup="_full"

elif [ "$arg1" = "inc" ]; then
  
  log "Entering incremental mode (Files modified after: '${last_b_time}')"

else

  log "Bad backup mode: '$1'. Aborting"
  do_cleanup 1
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

uncomp_size_bytes=$(get_backup_size "$db_file")
uncomp_size=$(get_human_read_size "$uncomp_size_bytes")

log "Uncompressed total backup size: ${uncomp_size}"

if [ -s "$db_file" ]; then

  tmp_file_name="${db_date}_${db_file_c}${full_backup}.tgz"
  output_file_gz="${DIR_OUTPUT}/${tmp_file_name}"
  pv_cmd=$(get_pv "$uncomp_size_bytes")

  log "Creating backup file: '${output_file_gz}'"
  
  eval "tar --ignore-failed-read -c -T \"$db_file\" 2>/dev/null | $pv_cmd   $GZIP > \"$output_file_gz\""
  ret_code=$?

  sync

  if [ $ret_code -ne 0 ]; then
    log "Error using tar to compress file"
    
    do_cleanup 1
  else

    if [ "$arg2" = "yes" ]; then
      echo -e "${WEEK_DIR}/${tmp_file_name}\t\t${arg1}\t${SEARCH_STARTED}" >> "$INDEX_FILE_OUTPUT" 2>/dev/null
    fi

   compressed_size=$(stat -c "%s" "$output_file_gz")
   compressed_size=$(get_human_read_size "$compressed_size")
   log "Compressed filesize is: ${compressed_size}"

  fi
else
  log "No files to backup"
fi

exit_success=1

if [ "$arg2" = "yes" ]; then
  echo "$SEARCH_STARTED" > "$LAST_MTIME_FILE"
else
  log "Not saving last modified time"
fi

log "Terminating naturally"

do_cleanup

