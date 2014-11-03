#!/bin/bash

#
# Example cron script:
#
# MAILTO="email@example.com"
# 
# 00 */4 * * *              root    /mnt/backup/abackup/abackup_schedule.sh > /dev/null
# 00 9 * * 0,2,3,4,5,6    root    /mnt/backup/abackup/abackup_schedule.sh force inc  > /dev/null
# 00 9 * * 1              root    /mnt/backup/abackup/abackup_schedule.sh force full > /dev/null
#
# Will make a full backup every monday at 9am
# whill make an incremental backup every other day of the week at 9am
# Will check each 4 hours, in case server was down arround 9am and make an incremental/full backup if more than X time as passed since last backup
#
# All errors will be sent by email to MAILTO
#



ENABLED=1

#dir="/mnt/backup/abackup"
dir="$(dirname "$(readlink -e "$0")")"
SCRIPT="${dir}/abackup.sh"

LOG_FILE="/var/log/abackup.log"

active="${dir}/.active"
db_dir="${dir}/db"

LAST_FULL_TIME_FILE="${db_dir}/.last_full_backup.schedule"
LAST_BACKUP_TIME="${db_dir}/.last_backup.schedule"

# Do not set the next two values to the exact same iteration time as the cron is scheduled to do a forced backup. Add some compensation

SECONDS_TO_ALLOW_NEW_BACKUP="90000" # One Day + 1 hour
SECONDS_TO_FULL_BACKUP="648000" # One Week + 12 hours

now=$(date +"%s")

allow_backup=$(( $now - $SECONDS_TO_ALLOW_NEW_BACKUP ))
trigger_full_mode=$(( $now - $SECONDS_TO_FULL_BACKUP ))

arg1=$(echo "$1" | awk '{print tolower($0)}')

if [ "$arg1" = "force" ]; then
  arg2=$(echo "$2" | awk '{print tolower($0)}')
fi

stamp() {
  echo $(date +"%Y-%m-%d %T.%3N")
}
log() {
  stamp=$(stamp)

  echo "[${stamp}] [SCHEDULE] $1" | tee -a "$LOG_FILE" 2>/dev/null
}
s_mkdir() {
  mkdir -p "$1" > /dev/null 2>&1
}

s_mkdir "$db_dir"

if [ "$ENABLED" != "1" ]; then
  log "Schedule check is disabled"

  exit 1
fi

if [ -f "$active" ]; then
  log "There is an active backup. Aborting"
 
  exit 1
fi


#log "Starting check"


if [ ! -x "$SCRIPT" ]; then
  log "'${SCRIPT}' not found, or not executable"

  exit 1
fi

[ -f "$LAST_BACKUP_TIME" ] && \
last_b_time=$(cat "$LAST_BACKUP_TIME" 2>/dev/null)

[ -f "$LAST_FULL_TIME_FILE" ] && \
last_f_time=$(cat "$LAST_FULL_TIME_FILE" 2>/dev/null)


if [ "$arg1" != "force" ] && [ "$last_b_time" != "" ] && [ "$allow_backup" -lt "$last_b_time" ]; then
  
  log "Not enought time as passed to allow a new backup"

  exit 1
fi

if [ "$last_f_time" = "" ] || [ "$trigger_full_mode" -ge "$last_f_time" ] || [ "$arg2" = "full" ]; then

  B_MODE="full"
  B_MODE_DESC="a full"
else

  B_MODE="inc"
  B_MODE_DESC="an incremental"
fi

if [ "$arg1" = "force" ]; then

  log "Scheduler is making $B_MODE_DESC forced backup"
else
  
  log "Scheduler is making $B_MODE_DESC backup because enough time as passed"
fi


export SHOW_PROGRESS=0
eval "$SCRIPT $B_MODE yes" #2>> "$LOG_ERROR"
ret_code=$?

if [ $ret_code -ne 0 ]; then
  log "Error ocurred while running '$SCRIPT'."

  exit 1
fi


echo "$now" > "$LAST_BACKUP_TIME"

if [ "$B_MODE" = "full" ]; then
 
  echo "$now" > "$LAST_FULL_TIME_FILE"

fi

log "Backup was successful"

