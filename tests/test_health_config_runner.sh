#!/bin/bash
# ==============================================================================
# NETDATA CUSTOM HEALTH CONFIG RUNNER
# Mục tiêu: Test nhanh file cấu hình health.d mà không cần reboot Netdata
# Tinh thần: KAIZEN - Tự động hóa quy trình kiểm tra thủ công
# ==============================================================================

# --- Cấu hình ---
NETDATA_API="http://127.0.0.1:19999"
HEALTH_CONF_DIR="/etc/netdata/health.d"
NETDATA_CLI="/usr/sbin/netdatacli" # Đường dẫn tới CLI của netdata

# Màu sắc cho output dễ nhìn
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Hàm log
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Validate Input
if [ -z "$1" ]; then
    log_err "Vui lòng cung cấp đường dẫn file config cần test."
    echo "Usage: $0 path/to/your_alert.conf"
    exit 1
fi

TEST_FILE=$1
FILENAME=$(basename "$TEST_FILE")
DEST_FILE="$HEALTH_CONF_DIR/$FILENAME"

# 2. PLAN & DO: Copy file và Reload Health Engine
log_info "Bắt đầu triển khai test file: $FILENAME"

if [ ! -f "$TEST_FILE" ]; then
    log_err "File không tồn tại: $TEST_FILE"
    exit 1
fi

# Copy file vào thư mục health (Cần quyền root hoặc sudo)
log_info "Copying config to $HEALTH_CONF_DIR..."
cp "$TEST_FILE" "$DEST_FILE"
if [ $? -ne 0 ]; then
    log_err "Không thể copy file. Kiểm tra quyền hạn (run as root?)."
    exit 1
fi

# Reload health configuration mà không restart netdata
# Đây là tính năng quan trọng để test nhanh (Hot Reload)
log_info "Reloading Netdata Health configuration..."
$NETDATA_CLI reload-health
sleep 2 # Đợi một chút để Netdata parse config

# 3. CHECK: Kiểm tra xem Alert đã được load vào hệ thống chưa
# Chúng ta sẽ curl API /api/v1/alarms để tìm tên alert
log_info "Verifying alert registration via API..."

# Giả sử trong file config, template tên là 'template_name'
# Chúng ta cần grep template name từ file config để check
TEMPLATE_NAME=$(grep "template:" "$TEST_FILE" | awk '{print $2}')

if [ -z "$TEMPLATE_NAME" ]; then
    log_err "Không tìm thấy 'template:' trong file config. File không hợp lệ?"
    # Cleanup
    rm "$DEST_FILE"
    exit 1
fi

# Query API
API_RESPONSE=$(curl -s "$NETDATA_API/api/v1/alarms?all")

if echo "$API_RESPONSE" | grep -q "$TEMPLATE_NAME"; then
    log_info "SUCCESS: Alert '$TEMPLATE_NAME' đã được load thành công vào bộ nhớ!"
    
    # Optional: Check trạng thái hiện tại (CLEAR, WARNING, CRITICAL)
    CURRENT_STATUS=$(echo "$API_RESPONSE" | grep -A 5 "\"$TEMPLATE_NAME\"" | grep "status" | head -1)
    log_info "Trạng thái hiện tại: $CURRENT_STATUS"
else
    log_err "FAILURE: Không tìm thấy alert '$TEMPLATE_NAME' trong API sau khi reload."
    log_err "Có thể file config sai cú pháp. Kiểm tra error.log của Netdata."
    
    # Cleanup dù fail để tránh rác hệ thống
    rm "$DEST_FILE"
    $NETDATA_CLI reload-health
    exit 1
fi

# 4. ACT: Dọn dẹp (Teardown)
# Bạn có thể comment dòng dưới nếu muốn giữ file lại để test thực tế
log_info "Dọn dẹp môi trường test..."
rm "$DEST_FILE"
$NETDATA_CLI reload-health

log_info "Test hoàn tất. Config hợp lệ về mặt cú pháp và khả năng load."
exit 0
