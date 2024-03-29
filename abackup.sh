#!/usr/bin/env bash

# needed awk or gawk
# recommended PV and PIGZ

# env variables:
# - CONFIG_DIR
# - STORE_DIR
# - FAIL_CONFIG_NOT_EXISTS
# - GZIP_COMPRESSION
# - MAX_PIGZ_CPU
# - SHA1SUM
# - NICENESS_LEVEL
# - USE_ENCRYPTION
# - USE_DEFAULT_INCLUDE

# to generate encryption key use: openssl rand -base64 128
# to decrypt encrypted file use: openssl enc -aes-256-cbc -d -md sha512 -pbkdf2 -iter 10001 -kfile ENC.KEY

#dir="/mnt/backup/abackup"
app_dir="$(dirname "$(readlink -f "$0")")"

dir="${CONFIG_DIR:-${app_dir}}"
base_dir_output="${STORE_DIR:-"/mnt/backup/store"}"

: "${FAIL_CONFIG_NOT_EXISTS:="1"}"
: "${GZIP_COMPRESSION:="-9"}"
: "${MAX_PIGZ_CPU:="2"}"
: "${SHA1SUM:="1"}"
#Backup process is very CPU intensive, use a low niceness (19) is the lowest
: "${NICENESS_LEVEL:="15"}"
: "${USE_ENCRYPTION:="1"}"
: "${USE_DEFAULT_INCLUDE:=""}"

LOG_FILE="${dir}/abackup.log"
BACKUP_API=""
[ "$USE_MEOCLOUD" = "1" ] && BACKUP_API="${app_dir}/meocloud.api.sh"

EPOCH_INIT="1970-01-01T00:00:00,000000000+00:00"

db="${dir}/db"
active="${dir}/.active"

INCLUDE_LIST="${dir}/include.list"
EXCLUDE_LIST="${dir}/exclude.list"
MAX_FILE_TRIES=30
LAST_MTIME_FILE="${db}/.last_mtime"
WEEK_DIR=$(date +"%Y%W")
INDEX_FILE_OUTPUT="${base_dir_output}/backup.index"
DIR_OUTPUT="${base_dir_output}/${WEEK_DIR}"
API_WORK_STATUS=0
ENCRYPTION_KEY="${dir}/enc.key"



awk=gawk

pid="$$"
exit_success=0

# Fill and uncomment EMAIL_RECIPIENTS and EMAIL_FROM to enable sending an email with a report
#EMAIL_RECIPIENTS="email@example.com"
#EMAIL_FROM="root@$(hostname)"

trap do_cleanup_signal SIGHUP SIGINT SIGTERM

###############################################################################
# Utilities
###############################################################################

if [ "$NICENESS_LEVEL" != "" ]; then
  USE_NICE="nice -n ${NICENESS_LEVEL}"
else
  USE_NICE=""
fi

rand_mt () {
 < /dev/urandom tr -dc A-Za-z0-9 | head -c${1:-16};echo;
}


LOG_BUFFER="/tmp/abackup_$(rand_mt)"


s_rm() {
  rm -f "$1" >/dev/null 2>&1
}

email_report() {
  local $subject
  local $content
  local $date
  date=$(date --date "$SEARCH_STARTED" 2>/dev/null)

  if [ ! -f "$LOG_BUFFER" ]; then
    log "No content to send"
    return 1
  fi
  
  if [ "$EMAIL_RECIPIENTS" != "" ]; then

    if [ "$exit_success" -eq 1 ]; then
      if [ "$API_WORK_STATUS" -eq 0 ]; then
        subject="[ABACKUP] SUCCESS - Started on: ${date}"
      else
        subject="[ABACKUP] API_FAIL - Started on: ${date}"
      fi
    else
       subject="[ABACKUP] FAILED - Started on: ${date}"
    fi

    content=$(cat "$LOG_BUFFER")

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

  [ "$BACKUP_API" != "" ] && [ "$API_END" != "" ] && eval "$API_END" "$exit_success"

  email_report

  [ -f "$LOG_BUFFER" ] && s_rm "$LOG_BUFFER"

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
  local msg
  local CONT

  if [ "$1" != "" ]; then
    CONT="$1"
  else
    read CONT
  fi

  msg="[$(stamp)] $CONT"

  echo "$msg" | tee -a "$LOG_BUFFER" "$LOG_FILE" #2>/dev/null
}


s_mkdir() {
  mkdir -p "$1" > /dev/null 2>&1
}

get_gzip() {
  if pigz -V >/dev/null 2>&1; then
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

get_encryption() {
  if [ "$ENCRYPTION_KEY" != "" ]; then
    echo " | $USE_NICE openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 10001 -salt -kfile \"${ENCRYPTION_KEY}\" "
  else
    echo ""
  fi
}


#gen_rand_mp() {
#  echo "${BASE_MOUNT_POINT}/$(rand_mt)"
#}

#gen_mount_point() {
#  local _GD_MPOINT="$(gen_rand_mp)"
#  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
#  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
#  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
#  [ -d "$_GD_MPOINT" ] && _GD_MPOINT="$(gen_rand_mp)"
#  echo "$_GD_MPOINT"
#}

get_backup_size() {

  if [ "$1" = "" ] || [ ! -f "$1" ]; then
    echo 0
  else
    echo $(cat "$1" |xargs -d \\n stat -c '%s' 2>/dev/null | $awk '{total+=$1} END {print total}' 2>/dev/null)
  fi
}

get_human_read_size() {
  if [ "$1" = "" ]; then
    echo "0 B"
  else
    echo $($awk -v sum=$1 'BEGIN{
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


arg1=$(echo "$1" | $awk '{print tolower($0)}')
arg2=$(echo "$2" | $awk '{print tolower($0)}')

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

s_mkdir "$db"
s_mkdir "$DIR_OUTPUT"

if [ "$FAIL_CONFIG_NOT_EXISTS" != "1" ]; then

  if [ ! -e "$INCLUDE_LIST" ]; then
    if [ "x$USE_DEFAULT_INCLUDE" != "x" ]; then
      log "[INFO] Populating '$INCLUDE_LIST' with defaults"
      echo "$USE_DEFAULT_INCLUDE" > "$INCLUDE_LIST"
      echo "${USE_DEFAULT_INCLUDE}/*" >> "$INCLUDE_LIST"
    else
      touch "$INCLUDE_LIST"
    fi
  fi

elif [ ! -s "$INCLUDE_LIST" ]; then
  log "Error - File list '$INCLUDE_LIST' does not exist or is empty!"

  exit 1

fi 

echo "$pid" > "$active"


# init API

if [ "$BACKUP_API" != "" ] && [  -f "$BACKUP_API" ] ; then

  . "$BACKUP_API"

  if [ "$API_INIT" != "" ]; then

    eval "$API_INIT"

    if [ $? -ne 0 ] ; then
      log "Error initializing remote backup API"
      BACKUP_API=""
    fi

  fi

fi

if [ -f "$LAST_MTIME_FILE" ] ; then
  last_b_time=$(cat "$LAST_MTIME_FILE")
else
  last_b_time=""
fi

if [ "$arg1" = "full" ] || [ "$last_b_time" = "" ] ; then
  last_b_time="$EPOCH_INIT"
  find_cmd_newermt=""

  arg1="full"

  log "Backup mode: full"
  full_backup="_full"

elif [ "$arg1" = "inc" ]; then
  find_cmd_newermt="-newermt \"${last_b_time}\""
  full_backup=""  
  log "Backup mode: incremental [Files modified after: '$(date --date "$last_b_time")']"
else

  log "Bad backup mode: '$1'. Aborting"
  do_cleanup 1
fi

db_dir="${db}/${WEEK_DIR}"
s_mkdir "$db_dir"

#check use of encryption key
if [ "$USE_ENCRYPTION" = "1" ] && [ "$ENCRYPTION_KEY" != "" ]; then
  if [ ! -e "$ENCRYPTION_KEY" ]; then
    log "[INFO] Generating new encryption key '$ENCRYPTION_KEY'"
    openssl rand -base64 128 > "$ENCRYPTION_KEY"
    chmod 600 "$ENCRYPTION_KEY"
  elif [ "$(stat -L -c "%a" $ENCRYPTION_KEY)" != "600" ]; then
    log "[WARNING] '$ENCRYPTION_KEY' needs to have 600 permissions for encryption to be enabled. Not using encryption!!"
    ENCRYPTION_KEY=""
  fi
else
  ENCRYPTION_KEY=""
fi

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

  #check use of encryption key
  if [ "$ENCRYPTION_KEY" != "" ]; then
      tmp_file_name="${tmp_file_name}.enc"
  fi

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

SEARCH_STARTED="@$(date --utc +%s)"

db_file_t="${db_file}.tmp"
log "Writing file index: '${db_file}'"


[ -f "$EXCLUDE_LIST" ] && \
exclude_files=$(cat "$EXCLUDE_LIST" | \
		while read f; do
		  if [ "$f" = "" ]; then continue; fi
		  echo -ne " ! -ipath \"${f}\""
		done)

while read f; do
  if [ "$f" = "" ]; then continue; fi

  eval "find \"$f\" ${find_cmd_newermt} ${exclude_files}" 2>/dev/null

done < "$INCLUDE_LIST" > "$db_file_t"

log "Trying to remove duplicates..."
$awk '!a[$0]++' "$db_file_t" > "$db_file" 2>/dev/null

s_rm "$db_file_t"

uncomp_size_bytes=$(get_backup_size "$db_file")
uncomp_size=$(get_human_read_size "$uncomp_size_bytes")

log "Uncompressed total backup size: ${uncomp_size}"


if [ -s "$db_file" ]; then

  pv_cmd=$(get_pv "$uncomp_size_bytes")
  enc_cmd=$(get_encryption)

  log "Creating backup file: '${output_file_gz}'"
  
  eval "$USE_NICE tar --numeric-owner --ignore-failed-read --no-recursion -c -T \"$db_file\" 2>/dev/null | ${pv_cmd} ${USE_NICE} ${GZIP} ${enc_cmd} > \"$output_file_gz\""
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
    date_not_utc="$(date --date "$SEARCH_STARTED" 2>/dev/null)"
    echo -e "${arg1}\t${checksum}${WEEK_DIR}\t${tmp_file_name}\t${compressed_size_bytes}\t${date_not_utc}" >> "$INDEX_FILE_OUTPUT" 
  fi

  if [ "$BACKUP_API" != "" ] && [  "$API_WORK" != "" ] ; then
    eval "$API_WORK" "$WEEK_DIR" "$tmp_file_name" "$output_file_gz"
    API_WORK_STATUS=$?
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

