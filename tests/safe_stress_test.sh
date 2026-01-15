#!/bin/bash
# ==============================================================================
# SAFE STRESS ENGINE FOR NETDATA TESTING
# Mục tiêu: Đẩy CPU lên cao để kích hoạt Alert nhưng KHÔNG làm treo máy.
# An toàn: Tự động hủy nếu CPU hiện tại > 50% hoặc chạm ngưỡng 95% khi test.
# ==============================================================================

# --- Cấu hình ---
# Ngưỡng an toàn để BẮT ĐẦU test (phải thấp hơn mức này mới chạy)
SAFE_START_THRESHOLD=50
# Mức tải mục tiêu cho Stress-ng (để lại 10% cho hệ thống thở)
TARGET_LOAD_PCT=90
# Thời gian chạy test (giây) - Đủ lâu để kích hoạt Alert delay 40s
DURATION=60

# --- Hàm lấy % CPU hiện tại ---
get_current_cpu() {
    # Lấy thông số idle từ top, sau đó lấy 100 - idle = usage
    # Dùng top -bn2 để lấy mẫu chính xác hơn, vì lần 1 top thường sai số
    cpu_idle=$(top -bn2 | grep "Cpu(s)" | tail -1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print $1}')
    cpu_usage=$(echo "100 - $cpu_idle" | bc)
    echo "$cpu_usage"
}

# --- 1. PRE-FLIGHT CHECK (Kiểm tra điều kiện bay) ---
echo ">>> [INIT] Đang kiểm tra trạng thái hệ thống..."
CURRENT_CPU=$(get_current_cpu)

# So sánh số thực trong bash cần dùng bc
if (( $(echo "$CURRENT_CPU > $SAFE_START_THRESHOLD" | bc -l) )); then
    echo "❌ [ABORT] CPU hiện tại đang cao ($CURRENT_CPU%)."
    echo "   Ngưỡng an toàn là $SAFE_START_THRESHOLD%. Hủy kiểm thử để bảo vệ hệ thống."
    exit 1
else
    echo "✅ [PASS] CPU hiện tại ổn định ($CURRENT_CPU%). Sẵn sàng kiểm thử."
fi

# --- 2. EXECUTE & MONITOR (Thực thi & Giám sát) ---
echo ">>> [ACTION] Bắt đầu kích tải CPU lên ~${TARGET_LOAD_PCT}% trong ${DURATION}s..."
echo "    (Nhấn Ctrl+C để dừng khẩn cấp)"

# Chạy stress-ng ở chế độ background (&)
# --cpu 0: Tự động detect số core
# --cpu-load: Chỉ cho phép worker chiếm 90% time slice
stress-ng --cpu 0 --cpu-load $TARGET_LOAD_PCT --timeout $DURATION --metrics-brief &
STRESS_PID=$!

# Vòng lặp Watchdog: Giám sát mỗi 3 giây
ELAPSED=0
while [ $ELAPSED -lt $DURATION ]; do
    sleep 5
    ELAPSED=$((ELAPSED+5))
    
    # Check nếu process stress-ng đã chết (ví dụ hết timeout)
    if ! kill -0 $STRESS_PID 2>/dev/null; then
        echo ">>> [INFO] Stress test đã hoàn thành."
        break
    fi

    # Kiểm tra lại CPU usage
    REALTIME_CPU=$(get_current_cpu)
    echo "    -> [Watchdog] CPU Usage: ${REALTIME_CPU}% (Target limit: 95%)"

    # EMERGENCY BRAKE: Nếu tổng CPU > 95% (tức là có process khác đang tranh chấp)
    if (( $(echo "$REALTIME_CPU > 95" | bc -l) )); then
        echo "⚠️ [EMERGENCY] Hệ thống quá tải (${REALTIME_CPU}%). Kích hoạt phanh khẩn cấp!"
        kill -9 $STRESS_PID
        echo "🛑 Đã kill tiến trình Stress ($STRESS_PID). Hệ thống an toàn."
        exit 1
    fi
done

echo ">>> [DONE] Kiểm thử hoàn tất an toàn."
exit 0
