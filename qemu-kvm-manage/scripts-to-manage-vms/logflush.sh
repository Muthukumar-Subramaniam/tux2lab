#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: logflush.sh                                                               #
# Description: Truncate all tux2lab service log files                                     #
# If you encounter any issues with this script, or have suggestions or feature requests,  #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues       #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab logflush

DESCRIPTION:
    Truncates all tux2lab service log files without restarting services.
    Log files are zeroed out in place (file handles remain valid)."
    exit 0
fi

readonly LOG_DIR="/tux2lab-data/logs"

if [[ ! -d "$LOG_DIR" ]]; then
    print_info "No log directory found at ${LOG_DIR}."
    exit 0
fi

print_cyan "--------------------------------------------------------------"
print_cyan "tux2lab Log Flush"
print_cyan "--------------------------------------------------------------"

total=0
for log_file in $(find "$LOG_DIR" -type f -name "*.log" -size +0c 2>/dev/null); do
    size=$(du -h "$log_file" | cut -f1)
    print_task "Flushing ${log_file#${LOG_DIR}/} (${size})..."
    sudo truncate -s 0 "$log_file"
    print_task_done
    total=$((total + 1))
done

if [[ $total -eq 0 ]]; then
    print_info "All logs are already empty."
else
    print_success "Flushed ${total} log file(s)."
fi
