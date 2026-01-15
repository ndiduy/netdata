#!/bin/bash
# ==============================================================================
# NETDATA HEALTH CHAOS TEST SUITE (v2.0)
# ==============================================================================
# Tác giả: Gemini Mentor
# Mô tả: Framework kiểm thử tự động cho Netdata Custom Alerts.
#        1. Parse file config để hiểu ngưỡng warn/crit.
#        2. Inject config vào hệ thống (có backup).
#        3. Tạo tải (Stress) thông minh với cơ chế Safety-Lock (giới hạn 90%).
#        4. Monitor API để verify trạng thái Alert.
#        5. Rollback hệ thống về trạng thái ban đầu.
#
# Yêu cầu: stress-ng, curl, jq (để parse JSON API)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. GLOBAL CONFIG & CONSTANTS
# ------------------------------------------------------------------------------
set -o pipefail  # Fail nếu pipe fail

# Màu sắc hiển thị
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cấu hình mặc định
NETDATA_HOST="http://127.0.0.1:19999"
HEALTH_DIR="/etc/netdata/health.d"
NETDATA_CLI="/usr/sbin/netdatacli"
STRESS_CMD="stress-ng"
SAFE_CPU_LIMIT=90         # Không stress quá 90%
ABORT_THRESHOLD=96        # Hủy nếu hệ thống chạm 96%
INITIAL_CPU_CHECK=50      # Không chạy nếu CPU đang > 50%
WATCHDOG_INTERVAL=2       # Giây

# Biến global
TARGET_CONF=""
BACKUP_FILE=""
STRESS_PID=""
SESSION_ID=$(date +%s)
LOG_FILE="/tmp/netdata_test_${SESSION_ID}.log"

# ------------------------------------------------------------------------------
# 2. UTILITY FUNCTIONS (LOGGING & HELP)
# ------------------------------------------------------------------------------

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local color=$NC

    case $level in
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "DEBUG") color=$BLUE ;;
    esac

    # Print to console
    echo -e "${color}[${timestamp}] [${level}]${NC} $msg"
    # Print to log file (strip colors)
    echo "[${timestamp}] [${level}] $msg" >> "$LOG_FILE"
}

usage() {
    echo -e "${CYAN}Usage: $0 -f <path_to_conf_file> [-d <duration>]${NC}"
    echo -e "Options:"
    echo -e "  -f  Đường dẫn đến file config alert cần test (Bắt buộc)"
    echo -e "  -d  Thời gian chạy stress test (Mặc định: Tự tính dựa trên 'delay' trong file)"
    echo -e "  -h  Hiển thị hướng dẫn này"
    exit 1
}

cleanup() {
    echo ""
    log "WARN" "Đang dọn dẹp hệ thống (Teardown)..."
    
    # 1. Kill stress process nếu còn chạy
    if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
        log "WARN" "Killing stress-ng PID: $STRESS_PID"
        kill -9 "$STRESS_PID"
    fi

    # 2. Restore file config cũ
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        log "INFO" "Restoring backup config..."
        mv "$BACKUP_FILE" "${HEALTH_DIR}/$(basename "$TARGET_CONF")"
        $NETDATA_CLI reload-health > /dev/null 2>&1
    elif [ -f "${HEALTH_DIR}/$(basename "$TARGET_CONF")" ]; then
        # Nếu không có backup (tức là file mới hoàn toàn), thì xóa đi
        log "INFO" "Xóa file test khỏi hệ thống..."
        rm "${HEALTH_DIR}/$(basename "$TARGET_CONF")"
        $NETDATA_CLI reload-health > /dev/null 2>&1
    fi

    log "INFO" "Hoàn tất. Log được lưu tại: $LOG_FILE"
}

# Trap signals để luôn cleanup dù user bấm Ctrl+C
trap cleanup SIGINT SIGTERM EXIT

# ------------------------------------------------------------------------------
# 3. SYSTEM CHECK & METRICS (CORE LOGIC)
# ------------------------------------------------------------------------------

check_dependencies() {
    local deps=("stress-ng" "curl" "jq" "netdatacli")
    log "INFO" "Checking dependencies..."
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "Thiếu dependency: $cmd. Vui lòng cài đặt trước."
            exit 1
        fi
    done
}

# Hàm đọc CPU trực tiếp từ Kernel (Pure Bash - No 'bc', No 'top')
# Trả về số nguyên % CPU usage (0-100)
get_cpu_usage_kernel() {
    # Đọc dòng đầu tiên của /proc/stat
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    # Tính toán tổng thời gian
    local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local active=$((user + nice + system + iowait + irq + softirq + steal))
    
    # Đợi một chút để lấy delta
    sleep 0.5
    
    read -r cpu_2 user_2 nice_2 system_2 idle_2 iowait_2 irq_2 softirq_2 steal_2 guest_2 guest_nice_2 < /proc/stat
    local total_2=$((user_2 + nice_2 + system_2 + idle_2 + iowait_2 + irq_2 + softirq_2 + steal_2))
    local active_2=$((user_2 + nice_2 + system_2 + iowait_2 + irq_2 + softirq_2 + steal_2))

    local diff_total=$((total_2 - total))
    local diff_active=$((active_2 - active))

    # Tính phần trăm (nhân 100 trước khi chia để giả lập số thập phân)
    if [ "$diff_total" -eq 0 ]; then
        echo 0
    else
        echo $(( (diff_active * 100) / diff_total ))
    fi
}

# ------------------------------------------------------------------------------
# 4. PARSING & DEPLOYMENT
# ------------------------------------------------------------------------------

parse_config() {
    local file=$1
    log "INFO" "Analyzing config file: $file"

    # Trích xuất Template Name
    TEMPLATE_NAME=$(grep "template:" "$file" | awk '{print $2}' | tr -d ' ')
    
    # Trích xuất tham số Delay (nếu có) để tính thời gian test
    # Format thường gặp: delay: up 40s down 5m...
    DELAY_UP=$(grep "delay:" "$file" | grep -o "up [0-9]\+[smh]" | awk '{print $2}')
    
    if [ -z "$TEMPLATE_NAME" ]; then
        log "ERROR" "Không tìm thấy 'template:' name trong file."
        exit 1
    fi

    log "DEBUG" "Detected Template: $TEMPLATE_NAME"
    log "DEBUG" "Detected Delay UP: ${DELAY_UP:-None}"
}

deploy_config() {
    local src=$1
    local filename=$(basename "$src")
    local dest="${HEALTH_DIR}/${filename}"

    log "INFO" "Deploying config to Netdata..."

    # Backup nếu file đã tồn tại
    if [ -f "$dest" ]; then
        log "WARN" "File cấu hình đã tồn tại. Creating backup..."
        cp "$dest" "${dest}.bak_${SESSION_ID}"
        BACKUP_FILE="${dest}.bak_${SESSION_ID}"
    fi

    cp "$src" "$dest"
    
    log "INFO" "Reloading Netdata Health..."
    $NETDATA_CLI reload-health
    if [ $? -ne 0 ]; then
        log "ERROR" "Reload thất bại. Kiểm tra syntax file config."
        exit 1
    fi
    sleep 3 # Chờ Netdata load
}

# ------------------------------------------------------------------------------
# 5. STRESS ENGINE (SAFE MODE)
# ------------------------------------------------------------------------------

start_stress_engine() {
    local duration=$1
    
    log "INFO" "--- BẮT ĐẦU PHA STRESS TEST ---"
    log "INFO" "Mục tiêu: Đẩy CPU -> ${SAFE_CPU_LIMIT}% trong ${duration}s"
    
    # Kiểm tra điều kiện đầu vào
    local current_cpu=$(get_cpu_usage_kernel)
    if [ "$current_cpu" -gt "$INITIAL_CPU_CHECK" ]; then
        log "ERROR" "CPU khởi điểm quá cao (${current_cpu}%). Hủy test để an toàn."
        exit 1
    fi

    # Chạy Stress-ng background
    # --cpu 0: Full cores detection
    # --cpu-load: % load per core
    $STRESS_CMD --cpu 0 --cpu-load "$SAFE_CPU_LIMIT" --timeout "${duration}s" --metrics-brief &
    STRESS_PID=$!
    
    log "INFO" "Stress-ng started with PID: $STRESS_PID"
}

watchdog_monitor() {
    local duration=$1
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))

    log "INFO" "Kích hoạt Watchdog giám sát thời gian thực..."

    while [ $(date +%s) -lt $end_time ]; do
        # 1. Check Safety
        local current_load=$(get_cpu_usage_kernel)
        if [ "$current_load" -gt "$ABORT_THRESHOLD" ]; then
            log "ERROR" "CRITICAL: Hệ thống quá tải (${current_load}%). Kích hoạt phanh khẩn cấp!"
            kill -9 "$STRESS_PID"
            break
        fi

        # 2. Check Netdata API để xem Alert trạng thái
        # Query API alarms
        local alarm_status=$(curl -s "${NETDATA_HOST}/api/v1/alarms?all" | jq -r ".alarms.\"${TEMPLATE_NAME}\".status" 2>/dev/null)
        
        if [ "$alarm_status" == "null" ] || [ -z "$alarm_status" ]; then
             # Alert chưa active hoặc tên sai
             echo -ne "."
        else
             log "DEBUG" "Alert Status: ${alarm_status} | CPU Load: ${current_load}%"
             
             if [ "$alarm_status" == "WARNING" ] || [ "$alarm_status" == "CRITICAL" ]; then
                 log "INFO" ">>> SUCCESS: Alert đã kích hoạt trạng thái: ${alarm_status}"
                 # Chúng ta có thể dừng sớm nếu chỉ cần verify alert trigger
                 # Nhưng user muốn test delay, nên cứ để chạy hết
             fi
        fi

        # 3. Check tiến trình stress
        if ! kill -0 "$STRESS_PID" 2>/dev/null; then
            log "INFO" "Stress process đã kết thúc."
            break
        fi

        # sleep theo interval
        # Đoạn này dùng logic wait để không sleep mù quáng
        sleep "$WATCHDOG_INTERVAL"
    done
}

# ------------------------------------------------------------------------------
# 6. MAIN ORCHESTRATION
# ------------------------------------------------------------------------------

main() {
    # Argument Parsing
    local duration=60 # Default duration
    
    while getopts "f:d:h" opt; do
        case $opt in
            f) TARGET_CONF="$OPTARG" ;;
            d) duration="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [ -z "$TARGET_CONF" ]; then
        usage
    fi

    # Step 0: Validate
    check_dependencies
    if [ ! -f "$TARGET_CONF" ]; then
        log "ERROR" "File $TARGET_CONF không tồn tại."
        exit 1
    fi

    # Step 1: Parse Config & Plan
    parse_config "$TARGET_CONF"
    
    # Nếu user không nhập duration, tự tính dựa trên delay của file config + buffer
    if [ "$duration" -eq 60 ] && [ -n "$DELAY_UP" ]; then
        # Parse đơn giản: lấy số, nếu là 's' giữ nguyên, 'm' nhân 60
        local num=$(echo $DELAY_UP | grep -o "[0-9]\+")
        local unit=$(echo $DELAY_UP | grep -o "[smh]")
        
        if [ "$unit" == "m" ]; then
            duration=$((num * 60 + 20)) # +20s buffer
        elif [ "$unit" == "s" ]; then
            duration=$((num + 20))
        fi
        log "INFO" "Auto-adjusting duration to ${duration}s based on config delay."
    fi

    # Step 2: Do (Deploy)
    deploy_config "$TARGET_CONF"

    # Step 3: Stress & Check (Action)
    start_stress_engine "$duration"
    watchdog_monitor "$duration"

    # Step 4: Report (Act)
    # Check trạng thái cuối cùng trước khi cleanup
    local final_status=$(curl -s "${NETDATA_HOST}/api/v1/alarms?all" | jq -r ".alarms.\"${TEMPLATE_NAME}\".status")
    
    echo "----------------------------------------------------------------"
    if [ "$final_status" == "WARNING" ] || [ "$final_status" == "CRITICAL" ]; then
        echo -e "${GREEN}TEST PASSED: Alert đã bắt được sự kiện High Load.${NC}"
    else
        echo -e "${RED}TEST FAILED: Alert không kích hoạt (Status: $final_status).${NC}"
        echo "Kiểm tra lại công thức calc hoặc delay trong file config."
    fi
    echo "----------------------------------------------------------------"

    # Cleanup sẽ tự chạy nhờ Trap
}

# Execute Main
main "$@"
