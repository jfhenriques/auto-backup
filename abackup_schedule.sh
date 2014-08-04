#!/bin/bash

ENABLED=1

dir="/mnt/backup/abackup"
SCRIPT="${dir}/abackup.sh"
LOG_FILE="/var/log/abackup.log"
LOG_ERROR="/var/log/abackup.error"
active="${dir}/.active"

LAST_FULL_TIME_FILE="${dir}/.last_full_backup.schedule"
LAST_BACKUP_TIME="${dir}/.last_backup.schedule"

# Dont set the next values to the exact same time as the cron os scheduled to do a dorce backup. Add some compensation time

SECONDS_TO_ALLOW_NEW_BACKUP="90000" # One Day + 1 hour
SECONDS_TO_FULL_BACKUP="648000" # One Week + 12 hours

#SECONDS_TO_ALLOW_NEW_BACKUP="5" # One Day
#SECONDS_TO_FULL_BACKUP="10" # One Week

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

if [ "$ENABLED" != "1" ]; then
  log "Schedule check is disabled"

  exit 1
fi

if [ -f "$active" ]; then
  log "There is an active backup. Aborting"
 
  exit 1
fi


log "Starting check"


if [ ! -x "$SCRIPT" ]; then
  log "'${SCRIPT}' not found, or not executable"

  exit 1
fi

[ -f "$LAST_BACKUP_TIME" ] && \
last_b_time=$(cat "$LAST_BACKUP_TIME" 2>/dev/null)

[ -f "$LAST_FULL_TIME_FILE" ] && \
last_f_time=$(cat "$LAST_FULL_TIME_FILE" 2>/dev/null)


if [ "$arg1" != "force" ] && [ "$last_b_time" != "" -a "$allow_backup" -lt "$last_b_time" ]; then
  
  log "Not enought time as passed to allow a new backup"

  exit 1
fi

if [ "$last_f_time" = "" ] || [ "$trigger_full_mode" -ge "$last_f_time" ] || [ "$arg2" = "full" ]; then

  B_MODE="full"
else

  B_MODE="inc"
fi

eval "$SCRIPT $B_MODE yes" 2>> "$LOG_ERROR"
ret_code=$?

if [ $ret_code -ne 0 ]; then
  log "Error ocurred while running '$SCRIPT'."

  exit 1
fi


echo "$now" > "$LAST_BACKUP_TIME"

if [ "$B_MODE" = "full" ]; then
 
  echo "$now" > "$LAST_FULL_TIME_FILE"

fi


