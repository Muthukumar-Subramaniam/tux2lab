# Define color codes
MAKE_IT_RED='\033[0;31m'
MAKE_IT_GREEN='\033[0;32m'
MAKE_IT_YELLOW='\033[0;33m'
MAKE_IT_BLUE='\033[0;34m'
MAKE_IT_CYAN='\033[0;36m'
MAKE_IT_WHITE='\033[0;37m'
MAKE_IT_MAGENTA='\033[0;35m'
RESET_COLOR='\033[0m' # Reset to default color

print_error() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_RED}[ERROR] ${1}${RESET_COLOR}"
}

print_success() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_GREEN}[SUCCESS] ${1}${RESET_COLOR}"
}

print_warning() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_YELLOW}[WARN] ${1}${RESET_COLOR}"
}

print_notify() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_WHITE}${1}${RESET_COLOR}"
}

print_info() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_MAGENTA}[INFO] ${1}${RESET_COLOR}"
}

# Task-level operations (always use nskip to allow same-line completion)
print_task() {
    echo -ne "${MAKE_IT_CYAN}[TASK] ${1}${RESET_COLOR}"
}

print_task_done() {
    echo -e " ${MAKE_IT_GREEN}[DONE]${RESET_COLOR}"
}

print_task_fail() {
    echo -e " ${MAKE_IT_RED}[FAIL]${RESET_COLOR}"
}

print_task_skip() {
    echo -e " ${MAKE_IT_YELLOW}[SKIP]${RESET_COLOR}"
}

print_skip() {
    echo -e "${MAKE_IT_YELLOW}[SKIP] ${1}${RESET_COLOR}"
}

print_yellow() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_YELLOW}${1}${RESET_COLOR}"
}

print_ready() {
    echo -e "${MAKE_IT_GREEN}[READY] ${1}${RESET_COLOR}"
}

print_summary() {
    echo -e "${MAKE_IT_WHITE}[SUMMARY] ${1}${RESET_COLOR}"
}

# Color-only print functions (no labels)
print_red() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_RED}${1}${RESET_COLOR}"
}

print_green() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_GREEN}${1}${RESET_COLOR}"
}

print_blue() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_BLUE}${1}${RESET_COLOR}"
}

print_cyan() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_CYAN}${1}${RESET_COLOR}"
}

print_magenta() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_MAGENTA}${1}${RESET_COLOR}"
}

print_white() {
    local flag="-e"; [[ "${2:-}" == "nskip" ]] && flag="-ne"
    echo $flag "${MAKE_IT_WHITE}${1}${RESET_COLOR}"
}
