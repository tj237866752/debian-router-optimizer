#!/usr/bin/env bash
# Debian 13 Router Sysctl Optimizer
# sing-box / TUN / nftables

set -Eeuo pipefail

CONFIG="/etc/sysctl.d/99zz-router-stable.conf"

OLD_FILES=(
    "/etc/sysctl.d/99-ip-forward.conf"
    "/etc/sysctl.d/99-kejilion-optimize.conf"
    "/etc/sysctl.d/99-network-buffer.conf"
    "/etc/sysctl.d/99-sb-router.conf"
    "/etc/sysctl.d/99-sing-box.conf"
)

# 检查 root
if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 用户运行此脚本。"
    exit 1
fi

# 检查 Debian 13
source /etc/os-release

if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
    echo "错误：此脚本仅支持 Debian 13。"
    exit 1
fi

# 检查必要命令
for cmd in sysctl ip chattr lsattr; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少必要命令：$cmd"
        exit 1
    }
done

# 自动识别默认出口网卡
DEFAULT_IF=$(ip -4 route show default |
    awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

if [[ -z "$DEFAULT_IF" ]]; then
    DEFAULT_IF=$(ip -6 route show default |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi

if [[ -z "$DEFAULT_IF" ]]; then
    echo "错误：无法识别默认出口网卡。"
    exit 1
fi

# 检测 TUN 网卡
TUN_IFS=()

while IFS= read -r iface; do
    [[ -n "$iface" ]] && TUN_IFS+=("$iface")
done < <(
    ip -o link show |
    awk -F': ' '{print $2}' |
    cut -d'@' -f1 |
    grep -E '^(tun|singtun|utun)[[:alnum:]_.-]*$' || true
)

echo
echo "======================================"
echo " Debian 13 旁路由网络优化"
echo "======================================"
echo
echo "默认出口网卡：$DEFAULT_IF"

if ((${#TUN_IFS[@]})); then
    echo "检测到 TUN 网卡：${TUN_IFS[*]}"
else
    echo "未检测到 TUN 网卡。"
fi

echo
echo "本脚本将执行："
echo "1. 备份现有 sysctl 配置"
echo "2. 清理五个旧优化配置"
echo "3. 写入统一优化配置"
echo "4. 加载并验证参数"
echo "5. 启用配置文件保护"
echo
echo "不会卸载软件，不会重启系统，不会操作 sing-box。"
echo
read -r -p "确认继续请输入大写 YES：" CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "已取消操作。"
    exit 0
fi

# 创建备份
BACKUP_DIR="/root/sysctl-router-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

for file in "$CONFIG" "${OLD_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$file")"
        cp -a "$file" "$BACKUP_DIR$file"
    fi
done

echo
echo "备份位置：$BACKUP_DIR"

# 解除旧配置保护
for file in "$CONFIG" "${OLD_FILES[@]}"; do
    if [[ -e "$file" ]]; then
        chattr -i "$file" 2>/dev/null || true
    fi
done

# 清理旧配置
for file in "${OLD_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        rm -f "$file"
        echo "已清理：$file"
    fi
done

# 写入统一配置
cat > "$CONFIG" <<EOF
# ==========================================
# Debian 13 Router - Stable Configuration
# sing-box / TUN / nftables
# ==========================================

# IPv4 / IPv6 forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Routing compatibility and security
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${DEFAULT_IF}.rp_filter = 0

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.${DEFAULT_IF}.send_redirects = 0

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffers
net.core.rmem_default = 16777216
net.core.rmem_max = 33554432
net.core.wmem_max = 16777216

# Network queues
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

# Local port range
net.ipv4.ip_local_port_range = 10240 65535

# Connection tracking
net.netfilter.nf_conntrack_max = 262144

# Neighbor table
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192

# File descriptor limit
fs.file-max = 1048576
EOF

# 添加当前存在的 TUN 网卡参数
for iface in "${TUN_IFS[@]}"; do
    cat >> "$CONFIG" <<EOF

# TUN interface: $iface
net.ipv4.conf.${iface}.rp_filter = 0
net.ipv4.conf.${iface}.send_redirects = 0
EOF
done

chmod 644 "$CONFIG"
chown root:root "$CONFIG"

echo
echo "正在加载配置……"

if ! sysctl --system; then
    echo "错误：sysctl 配置加载失败。"
    echo "备份保留在：$BACKUP_DIR"
    exit 1
fi

# 验证配置
declare -A EXPECTED=(
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv6.conf.all.forwarding"]="1"
    ["net.ipv4.conf.all.rp_filter"]="0"
    ["net.ipv4.conf.default.rp_filter"]="0"
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.default.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv4.conf.default.send_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["net.ipv6.conf.default.accept_redirects"]="0"
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["net.core.rmem_default"]="16777216"
    ["net.core.rmem_max"]="33554432"
    ["net.core.wmem_max"]="16777216"
    ["net.core.netdev_max_backlog"]="16384"
    ["net.core.somaxconn"]="4096"
    ["net.ipv4.tcp_max_syn_backlog"]="8192"
    ["net.ipv4.ip_local_port_range"]="10240 65535"
    ["net.netfilter.nf_conntrack_max"]="262144"
    ["net.ipv4.neigh.default.gc_thresh1"]="1024"
    ["net.ipv4.neigh.default.gc_thresh2"]="4096"
    ["net.ipv4.neigh.default.gc_thresh3"]="8192"
    ["fs.file-max"]="1048576"
    ["net.ipv4.conf.${DEFAULT_IF}.rp_filter"]="0"
    ["net.ipv4.conf.${DEFAULT_IF}.send_redirects"]="0"
)

for iface in "${TUN_IFS[@]}"; do
    EXPECTED["net.ipv4.conf.${iface}.rp_filter"]="0"
    EXPECTED["net.ipv4.conf.${iface}.send_redirects"]="0"
done

FAILED=0

echo
echo "正在验证参数……"

for key in "${!EXPECTED[@]}"; do
    actual=$(sysctl -n "$key" 2>/dev/null | xargs || true)
    expected="${EXPECTED[$key]}"

    if [[ "$actual" == "$expected" ]]; then
        echo "[正常] $key = $actual"
    else
        echo "[失败] $key"
        echo "       期望：$expected"
        echo "       实际：$actual"
        FAILED=1
    fi
done

if [[ $FAILED -ne 0 ]]; then
    echo
    echo "参数验证失败，不启用文件保护。"
    echo "备份位置：$BACKUP_DIR"
    exit 1
fi

# 启用文件保护
if ! chattr +i "$CONFIG"; then
    echo "错误：配置生效，但文件保护设置失败。"
    exit 1
fi

ATTR=$(lsattr -d "$CONFIG" | awk '{print $1}')

if [[ "$ATTR" != *i* ]]; then
    echo "错误：未能确认文件保护属性。"
    exit 1
fi

echo
echo "======================================"
echo " 优化完成"
echo "======================================"
echo
echo "配置文件：$CONFIG"
echo "备份目录：$BACKUP_DIR"
echo "文件保护：已启用"
echo

if systemctl is-active --quiet sing-box 2>/dev/null; then
    echo "sing-box 状态：active"
else
    echo "sing-box 状态：未运行或未安装"
fi

echo
echo "修改配置前执行："
echo "chattr -i $CONFIG"
echo
echo "修改完成后重新保护："
echo "chattr +i $CONFIG"
echo
echo "注意：chattr +i 不是安全边界，root 用户可以解除保护。"
echo "如果 TUN 网卡在脚本运行后才创建，需要补充对应接口参数。"
echo
