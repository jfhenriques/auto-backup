#!/bin/bash


#dir="/mnt/backup/abackup"
dir="$(dirname "$(readlink -e "$0")")"
base_dir_output="/mnt/backup/store"

LOG_FILE="/var/log/abackup.log"

GZIP_COMPRESSION="-9"
MAX_PIGZ_CPU=2
SHA1SUM="1"
#Backup process is very CPU intensive, use a low niceness (19) is the lowest
NICENESS_LEVEL="15"


db="${dir}/db"
active="${dir}/.active"

INCLUDE_LIST="${dir}/backup.list"
EXCLUDE_LIST="${dir}/exclude.list"
MAX_FILE_TRIES=30
LAST_MTIME_FILE="${db}/.last_mtime"
WEEK_DIR=$(date +"%Y%W")
INDEX_FILE_OUTPUT="${base_dir_output}/backup.index"
DIR_OUTPUT="${base_dir_output}/${WEEK_DIR}"
#DIR_OUTPUT="/mnt/gdrive"

#GDRIVE api is currently broken for large files
#BACKUP_API="gdrive.api"
BASE_MOUNT_POINT="${dir}/.mpoint"

pid="$$"
exit_success=0

# Fill and uncomment EMAIL_RECIPIENTS and EMAIL_FROM to enable sending an email with a report
#EMAIL_RECIPIENTS="email@example.com"
#EMAIL_FROM="root@$(hostname)"

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
  do_cleanup 1
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
#get_dbdate() {
#  echo "$(date +"%Y%m%d")"
#}
get_dbfulldate() {
  echo "$(date +"%Y%m%d%H%M%S")"
}

#get_ym() {
#  echo "$(date +"%Y%m")"
#}

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
  if [ "$SHOW_PROGRESS" = "" -o "$SHOW_PROGRESS" = "1" ] && pv -V >/dev/null 2>&1; then
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


arg1=$(echo "$1" | awk '{print tolower($0)}')
arg2=$(echo "$2" | awk '{print tolower($0)}')

if [ "$arg1" = "" ]; then
  arg1="inc"

  log "Starting a new backup"
else

  log "Starting a forced backup"
fi

if [ "$arg2" = "" ]; then
  arg2="yes"
fi



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


[ -f "$LAST_MTIME_FILE" ] && \
last_b_time=$(cat "$LAST_MTIME_FILE" | xargs -0 date --utc --date 2>/dev/null)
find_cmd_newermt="-newermt \"${last_b_time}\""

if [ "$arg1" = "full" ] || [ "$last_b_time" = "" ] ; then
  last_b_time="Thu Jan  1 00:00:00 UTC 1970"
  find_cmd_newermt=""

  arg1="full"

  log "Backup mode: full"
  full_backup="_full"

elif [ "$arg1" = "inc" ]; then

  full_backup=""  
  log "Backup mode: incremental [Files modified after: '$(date --date "$last_b_time")']"
else

  log "Bad backup mode: '$1'. Aborting"
  do_cleanup 1
fi

db_dir="${db}/${WEEK_DIR}"
s_mkdir "$db_dir"

for ((i=1; i<=MAX_FILE_TRIES; i++)); do

  try_date="$(get_dbfulldate)"
  formatted_i="$(printf "%04d" "$i")"

  if [ "$i" -gt 1 ]; then
    base_suffix="_${formatted_i}"
  else
    base_suffix=""
  fi

  db_file="${db_dir}/${try_date}${base_suffix}.index"
  tmp_file_name="${try_date}${base_suffix}${full_backup}.tgz"
  output_file_gz="${DIR_OUTPUT}/${tmp_file_name}"

  if [ ! -e "$db_file" ] && [ ! -e "$output_file_gz" ]; then
    break;
  fi

  if [ "$i" -eq "$MAX_FILE_TRIES" ]; then
    log "Error - Tried ${MAX_FILE_TRIES} time(s) to find a suitable backup file name with no luck. Please run the script again later"
    do_cleanup 1
  fi
 
  sleep 1 
done

SEARCH_STARTED=$(date --utc)

db_file_t="${db_file}.tmp"
log "Writing file index: '${db_file}'"


[ -f "$EXCLUDE_LIST" ] && \
exclude_files=$(cat "$EXCLUDE_LIST" | \
		while read f; do
		  if [ "$f" = "" ]; then continue; fi
		  echo -ne " ! -ipath \"${f}/*\""
		done)

while read f; do
  if [ "$f" = "" ]; then continue; fi

  eval "find \"$f\" ${find_cmd_newermt} -type f ${exclude_files} ! -ipath \"${BASE_MOUNT_POINT}/*\"" 2>/dev/null

done < "$INCLUDE_LIST" > "$db_file_t"

log "Trying to remove duplicates..."
awk '!a[$0]++' "$db_file_t" > "$db_file" 2>/dev/null

s_rm "$db_file_t"

uncomp_size_bytes=$(get_backup_size "$db_file")
uncomp_size=$(get_human_read_size "$uncomp_size_bytes")

log "Uncompressed total backup size: ${uncomp_size}"

if [ -s "$db_file" ]; then

  pv_cmd=$(get_pv "$uncomp_size_bytes")

  log "Creating backup file: '${output_file_gz}'"
  
  eval "nice -n \"${NICENESS_LEVEL}\" tar --ignore-failed-read -c -T \"$db_file\" 2>/dev/null | $pv_cmd nice -n \"${NICENESS_LEVEL}\" $GZIP > \"$output_file_gz\""
  ret_code=$?

  sync

  if [ $ret_code -ne 0 ]; then
    log "Error using tar to compress file"
    
    do_cleanup 1
  fi

  compressed_size_bytes=$(stat -c "%s" "$output_file_gz")
  compressed_size=$(get_human_read_size "$compressed_size_bytes")
  log "Compressed filesize is: ${compressed_size}"

  if [ "$SHA1SUM" = "1" ]; then
    
    checksum_b="$(sha1sum -b "$output_file_gz" |cut -d ' ' -f 1)"
    checksum="${checksum_b}\t"

    log "File sha1sum is: ${checksum_b}"
  else

    checksum=""
  fi

  if [ "$arg2" = "yes" ]; then
    date_not_utc="$(date -d "$SEARCH_STARTED" 2>/dev/null)"
    echo -e "${arg1}\t${checksum}${WEEK_DIR}\t${tmp_file_name}\t${compressed_size_bytes}\t${date_not_utc}" >> "$INDEX_FILE_OUTPUT" 
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

