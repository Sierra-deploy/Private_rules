# 1. 安装依赖
apt-get update && apt-get install -y vnstat jq bc iptables-persistent iproute2 2>/dev/null || yum install -y vnstat jq bc iptables-services iproute2

# 2. 写入【生产级】流量限制脚本
cat << 'EOF' > /usr/local/bin/limit_daily_traffic.sh
#!/bin/bash
# ===============================================================
# 每日出站流量限制脚本 (GCP 200G 薅羊毛专用 - 生产级)
# 作者: Claude AI
# 设定: 每天 6GB 出站流量上限
# ===============================================================

set -e  # 遇到错误立即退出，防止误操作

# --- 配置 ---
LIMIT_GB=6
LIMIT_BYTES=$(echo "$LIMIT_GB * 1024 * 1024 * 1024" | bc | awk '{printf "%.0f", $1}')
LOG_FILE="/var/log/daily_traffic_limit.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- 自动检测公网接口 ---
INTERFACE=$(ip -4 route list 0/0 | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    log "ERROR: Could not detect default network interface."
    exit 1
fi

# --- 刷新 vnstat 数据 ---
vnstat -i "$INTERFACE" --update >/dev/null 2>&1 || true

# --- 获取今日出站流量 (精确匹配年/月/日) ---
YEAR=$(date +%Y)
MONTH=$(date +%-m)  # 不带前导零
DAY=$(date +%-d)    # 不带前导零

# 使用 jq 精确匹配今日数据
TODAY_TX=$(vnstat -i "$INTERFACE" --json 2>/dev/null | jq -r \
    ".interfaces[0].traffic.day[] | select(.date.year==$YEAR and .date.month==$MONTH and .date.day==$DAY) | .tx" 2>/dev/null)

# 安全处理：如果获取失败或为空，默认为0
if [[ -z "$TODAY_TX" || "$TODAY_TX" == "null" || ! "$TODAY_TX" =~ ^[0-9]+$ ]]; then
    TODAY_TX=0
fi

# 转换单位仅用于日志显示
TODAY_GB=$(echo "scale=2; $TODAY_TX / 1024 / 1024 / 1024" | bc)
log "Interface: $INTERFACE | Today TX: ${TODAY_GB} GB / Limit: ${LIMIT_GB} GB"

# --- 核心判断 ---
if [ "$TODAY_TX" -gt "$LIMIT_BYTES" ]; then
    log "ALERT: Traffic exceeded! Blocking outbound traffic..."
    
    # 确保 SSH 放行规则在最前 (防止失联)
    iptables -C OUTPUT -p tcp --sport 20202 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p tcp --sport 20202 -j ACCEPT
    iptables -C OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p tcp --sport 22 -j ACCEPT
    
    # 阻断其他所有出站
    iptables -C OUTPUT -j DROP 2>/dev/null || iptables -A OUTPUT -j DROP
    
    log "Outbound traffic BLOCKED (SSH preserved)."
else
    # 未超标：清理阻断规则 (实现次日自动恢复)
    if iptables -C OUTPUT -j DROP 2>/dev/null; then
        log "Traffic within limit. Removing block..."
        iptables -D OUTPUT -j DROP
        log "Outbound traffic UNBLOCKED."
    fi
fi
EOF

# 3. 权限
chmod +x /usr/local/bin/limit_daily_traffic.sh

# 4. 设置定时任务 (每5分钟)
(crontab -l 2>/dev/null | grep -v "limit_daily_traffic.sh"; echo "*/5 * * * * /usr/local/bin/limit_daily_traffic.sh") | crontab -

echo "✅ 生产级脚本部署完成！"
echo "   接口: $(ip -4 route list 0/0 | awk '{print $5}' | head -n1)"
echo "   日志: /var/log/daily_traffic_limit.log"
echo "   限制: 每日出站 ${LIMIT_GB}GB，超额自动断网，次日自动恢复。"
