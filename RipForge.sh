#!/bin/bash

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Directories
OUTPUT_DIRECTORY="~/RipForge/rips"
LOGS_DIRECTORY="~/RipForge/logs"
HANDBRAKE_PRESET="<prefered handbrake preset>"
LOG_FILE="$LOGS_DIRECTORY/error.log"
PUSHOVER_TOKEN="<pushover_token>"
PUSHOVER_USER="<pushover_user>"

# Function to send a message via Pushover
send_pushover_notification() {
    curl -s \
        -F "token=$PUSHOVER_TOKEN" \
        -F "user=$PUSHOVER_USER" \
        -F "title=$1" \
        -F "message=$2" \
        https://api.pushover.net/1/messages.json > /dev/null
}

# Max log size (10 MB)
MAX_LOG_SIZE=$((1024 * 1024 * 10))

# Record the start time
start_time=$(date +%s)

# Error reporting function
report_error() {
    local message="$1"
    echo "Error: $message" >&2
    log_message "ERROR" "$message"
    send_pushover_notification "RipForge" "Error: $message"
    eject_dvd  # Eject DVD on failure
    log_elapsed_time
    exit 1
}

# Logging function with levels and timestamps
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date)] [$level] $message" >> "$LOG_FILE"
}

# Log rotation function (rotates log file if it exceeds the max size)
rotate_logs() {
    local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ $log_size -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log_message "INFO" "Log file rotated. New log started."
    fi
}

# Ensure output and logs directories exist
mkdir -p "$OUTPUT_DIRECTORY" || report_error "Failed to create output directory."
mkdir -p "$LOGS_DIRECTORY" || report_error "Failed to create logs directory."

# Check dependencies (MakeMKV, HandBrakeCLI, diskutil)
check_dependencies() {
    command -v MakeMKVcon >/dev/null 2>&1 || report_error "MakeMKV is not installed."
    command -v HandBrakeCLI >/dev/null 2>&1 || report_error "HandBrakeCLI is not installed."
    command -v diskutil >/dev/null 2>&1 || report_error "diskutil is not installed."
}

# Eject DVD
eject_dvd() {
    local dvd_device=$(diskutil list | grep -B2 "Optical" | grep "/dev/disk" | awk '{print $1}')
    
    if [ -n "$dvd_device" ]; then
        log_message "INFO" "Ejecting DVD from device: $dvd_device"
        diskutil eject "$dvd_device" || log_message "WARNING" "Failed to eject the DVD from $dvd_device."
    else
        log_message "WARNING" "No Optical Drive detected dynamically; attempting to eject from /dev/disk2."
        diskutil eject /dev/disk2 || log_message "WARNING" "Failed to eject DVD from fallback device /dev/disk2."
    fi
}


# Extract DVD title using diskutil
get_dvd_title() {
    local volume_name=$(diskutil info /dev/disk2 | grep "Volume Name" | awk -F: '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    
    if [ -z "$volume_name" ]; then
        volume_name="Unknown_Disc_$(date +'%Y-%m-%d_%H-%M-%S')"
        log_message "WARNING" "Could not retrieve DVD title. Using fallback: $volume_name"
    else
        log_message "INFO" "Extracted DVD title: $volume_name"
    fi
    
    echo "$volume_name"
}

# Log total elapsed time
log_elapsed_time() {
    end_time=$(date +%s)
    elapsed_time=$(( end_time - start_time ))
    log_message "INFO" "Total elapsed time: $((elapsed_time / 60)) minutes and $((elapsed_time % 60)) seconds."
}

# Check dependencies
check_dependencies

# Rotate logs if needed
rotate_logs

# Get the DVD title
dvd_title=$(get_dvd_title)

send_pushover_notification "RipForge" "RipForge Initiated - Processing '$dvd_title'"

# Rip the DVD using MakeMKVcon
rip_command="/usr/local/bin/MakeMKVcon mkv disc:0 all \"$OUTPUT_DIRECTORY\""

log_message "INFO" "Executing: $rip_command"
eval $rip_command 2>&1 | tee -a "$LOG_FILE"
result=$?

if [ $result -ne 0 ]; then
    report_error "MakeMKVcon failed to rip the disc."
else
    log_message "INFO" "Successfully ripped the DVD."
    send_pushover_notification "RipForge" "DVD ripped successfully."
fi
# Define the output file path with spaces in the title
output_file="$OUTPUT_DIRECTORY/$dvd_title.mp4"

if [[ ! -f "$OUTPUT_DIRECTORY/title.mkv" ]]; then
    report_error "title.mkv not found for HandBrake encoding."
fi

# Log details of title.mkv to confirm it’s updated with new DVD content
ls -lh "$OUTPUT_DIRECTORY/title.mkv" >> "$LOG_FILE"

# Start HandBrake encoding
/usr/local/bin/HandBrakeCLI -i "$OUTPUT_DIRECTORY/title.mkv" -o "$OUTPUT_DIRECTORY/${dvd_title}.mp4" --preset "$HANDBRAKE_PRESET" >/dev/null 2>>"$LOG_FILE"

log_message "INFO" "Executing HandBrake: $handbrake_command"
eval $handbrake_command >/dev/null 2>>"$LOG_FILE"
handbrake_result=$?

if [ $handbrake_result -ne 0 ]; then
    report_error "HandBrakeCLI failed."
else
    log_message "INFO" "Successfully encoded the main feature to $output_file."
    send_pushover_notification "RipForge" "Encoding completed successfully."
fi

# Clean up: remove the original MKV files
log_message "INFO" "Removing original MKV files..."
rm "$OUTPUT_DIRECTORY"/*.mkv || log_message "WARNING" "Failed to remove MKV files."

# Eject DVD on successful completion
log_message "INFO" "Ripping and encoding completed successfully."
eject_dvd

# Log the total elapsed time
log_elapsed_time
send_pushover_notification "RipForge" "Process completed successfully!"
