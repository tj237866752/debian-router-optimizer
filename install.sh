#!/usr/bin/env bash
# ==========================================================
# Debian 13 Router Optimizer
# PVE VM / Physical Machine
# sing-box / TUN / nftables
# ==========================================================

set -Eeuo pipefail

CONFIG="/etc/sysctl.d/99zz-router-stable.conf"
STATE="/var/lib/debian-router-optimizer"
BACKUP_ROOT="/root/debian-router-backups"
SCRIPT_NAME="Debian Router Optimizer"

OLD_FILES=(
    "/etc/sysctl.d/99-ip-forward.conf"
    "/etc/sysctl.d/99-kejilion-optimize.conf"
    "/etc/sysctl.d/99-network-buffer.conf"
    "/etc/sysctl.d/99-sb-router.conf"
    "/etc/sysctl.d/99-sing-box.conf"
)

# ----------------------------------------------------------
# 基础检查
# ----------------------------------------------------------

check_system() {
    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 用户运行。"
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        echo "无法识别系统。"
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "debian" || "$VERSION_ID" != "13" ]]; then
        echo "本脚本仅支持 Debian 13。"
        exit 1
    fi

    for cmd in sysctl ip chattr lsattr; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "缺少必要命令：$cmd"
            exit 1
        }
    done
}

# ----------------------------------------------------------
# 自动检测网络接口
# ----------------------------------------------------------

detect_interfaces() {
    DEFAULT_IF=$(
        ip -4 route show default |
        awk 'NR==1 {
            for(i=1;i<=NF;i++)
                if($i=="dev"){print $(i+1);exit}
        }'
    )

    if [[ -z "$DEFAULT_IF" ]]; then
        DEFAULT_IF=$(
            ip -6 route show default |
            awk 'NR==1 {
                for(i=1;i<=NF;i++)
                    if($i=="dev"){print $(i+1);exit}
            }'
        )
    fi

    TUN_IFS=()

    while IFS= read -r iface; do
        [[ -n "$iface" ]] && TUN_IFS+=("$iface")
    done < <(
        ip -o link show |
        awk -F': ' '{print $2}' |
        cut -d'@' -f1 |
        grep -E '^(tun|singtun|utun)[[:alnum:]_.-]*$' || true
    )
}

# ----------------------------------------------------------
# 文件保护
# ----------------------------------------------------------

unlock_config() {
    if [[ -e "$CONFIG" ]]; then
        chattr -i "$CONFIG" 2>/dev/null || true
    fi
}

lock_config() {
    if [[ -e "$CONFIG" ]]; then
        if ! chattr +i "$CONFIG"; then
            echo "文件保护启用失败。"
            return 1
        fi
    fi
}

# ----------------------------------------------------------
# 备份
# ----------------------------------------------------------

create_backup() {
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)

    BACKUP_DIR="$BACKUP_ROOT/$stamp"

    mkdir -p "$BACKUP_DIR/files"

    local file

    for file in "$CONFIG" "${OLD_FILES[@]}" /etc/sysctl.conf; do
        if [[ -f "$file" ]]; then
            mkdir -p "$BACKUP_DIR/files$(dirname "$file")"
            cp -a "$file" "$BACKUP_DIR/files$file"
        fi
    done

    printf '%s\n' "$BACKUP_DIR"
}

# ----------------------------------------------------------
# 参数生成
# ----------------------------------------------------------

generate_config() {
    local IPV4_FORWARD="$1"
    local IPV6_FORWARD="$2"
    local BBR="$3"
    local TUNING="$4"

    detect_interfaces

    if [[ -z "$DEFAULT_IF" ]]; then
        echo "无法检测默认出口网卡。"
        return 1
    fi

    local IPV4_VALUE=0
    local IPV6_VALUE=0

    [[ "$IPV4_FORWARD" == "1" ]] && IPV4_VALUE=1
    [[ "$IPV6_FORWARD" == "1" ]] && IPV6_VALUE=1

    {
        cat <<EOF
# ==========================================
# Debian 13 Router - Stable Configuration
# Managed by $SCRIPT_NAME
# ==========================================

# IPv4 / IPv6 forwarding
net.ipv4.ip_forward = $IPV4_VALUE
net.ipv6.conf.all.forwarding = $IPV6_VALUE

# Routing compatibility
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${DEFAULT_IF}.rp_filter = 0

# Redirect security
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.${DEFAULT_IF}.send_redirects = 0

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

EOF

        # IPv6 RA 处理
        if [[ "$IPV6_VALUE" == "1" ]]; then
            if [[ -r "/proc/sys/net/ipv6/conf/${DEFAULT_IF}/accept_ra" ]]; then
                echo "net.ipv6.conf.${DEFAULT_IF}.accept_ra = 2"
            fi
        fi

        # BBR
        if [[ "$BBR" == "1" ]]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi

        # 网络缓冲区与队列
        if [[ "$TUNING" == "1" ]]; then
            cat <<EOF
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
        fi

        # TUN 参数
        for iface in "${TUN_IFS[@]}"; do
            cat <<EOF

# TUN interface: $iface
net.ipv4.conf.${iface}.rp_filter = 0
net.ipv4.conf.${iface}.send_redirects = 0
EOF
        done

    } > "$CONFIG"

    chmod 644 "$CONFIG"
    chown root:root "$CONFIG"
}

# ----------------------------------------------------------
# 验证参数
# ----------------------------------------------------------

verify_value() {
    local key="$1"
    local expected="$2"
    local actual

    actual=$(sysctl -n "$key" 2>/dev/null | xargs || true)

    if [[ "$actual" == "$expected" ]]; then
        printf "[正常] %s = %s\n" "$key" "$actual"
        return 0
    else
        printf "[失败] %s 期望=%s 实际=%s\n" \
            "$key" "$expected" "$actual"
        return 1
    fi
}

# ----------------------------------------------------------
# 查看当前配置
# ----------------------------------------------------------

show_status() {
    echo
    echo "========== 当前网络参数 =========="

    local keys=(
        net.ipv4.ip_forward
        net.ipv6.conf.all.forwarding
        net.ipv4.conf.all.rp_filter
        net.core.default_qdisc
        net.ipv4.tcp_congestion_control
        net.core.rmem_default
        net.core.rmem_max
        net.core.wmem_max
        net.core.netdev_max_backlog
        net.core.somaxconn
        net.ipv4.tcp_max_syn_backlog
        net.ipv4.ip_local_port_range
        net.netfilter.nf_conntrack_max
        fs.file-max
    )

    local key

    for key in "${keys[@]}"; do
        printf "%-45s " "$key"
        sysctl -n "$key" 2>/dev/null || echo "不可用"
    done

    echo
    echo "默认路由："
    ip route show default

    echo
    echo "IPv6 默认路由："
    ip -6 route show default

    echo
    echo "配置文件保护："
    lsattr -d "$CONFIG" 2>/dev/null || echo "配置文件不存在"

    echo
    echo "sing-box 状态："
    systemctl is-active sing-box 2>/dev/null || true
    echo "=================================="
}

# ----------------------------------------------------------
# 安装或更新
# ----------------------------------------------------------

install_config() {
    echo
    echo "========== 安装配置 =========="

    detect_interfaces

    if [[ -z "$DEFAULT_IF" ]]; then
        echo "未检测到默认出口网卡，取消安装。"
        return
    fi

    echo "默认出口网卡：$DEFAULT_IF"
    echo "检测到 TUN：${TUN_IFS[*]:-无}"

    echo
    echo "IPv4 转发："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择 [默认 1]：" choice
    local IPV4=1
    [[ "$choice" == "2" ]] && IPV4=0

    echo
    echo "IPv6 转发："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择 [默认 2]：" choice
    local IPV6=0
    [[ "$choice" == "1" ]] && IPV6=1

    echo
    echo "BBR + fq："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择 [默认 1]：" choice
    local BBR=1
    [[ "$choice" == "2" ]] && BBR=0

    echo
    echo "网络缓冲区及队列优化："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择 [默认 1]：" choice
    local TUNING=1
    [[ "$choice" == "2" ]] && TUNING=0

    echo
    echo "========== 配置确认 =========="
    echo "IPv4 转发：$([[ "$IPV4" == 1 ]] && echo 开启 || echo 关闭)"
    echo "IPv6 转发：$([[ "$IPV6" == 1 ]] && echo 开启 || echo 关闭)"
    echo "BBR + fq：$([[ "$BBR" == 1 ]] && echo 开启 || echo 关闭)"
    echo "网络参数优化：$([[ "$TUNING" == 1 ]] && echo 开启 || echo 关闭)"
    echo
    read -r -p "输入 YES 确认安装：" confirm

    [[ "$confirm" == "YES" ]] || {
        echo "已取消。"
        return
    }

    create_backup >/dev/null
    echo "备份位置：$BACKUP_DIR"

    unlock_config

    # 清理旧配置
    local file
    for file in "${OLD_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            chattr -i "$file" 2>/dev/null || true
            rm -f "$file"
        fi
    done

    generate_config "$IPV4" "$IPV6" "$BBR" "$TUNING"

    echo
    echo "正在加载配置……"

    if ! sysctl --system; then
        echo "加载失败。请使用备份恢复功能。"
        return 1
    fi

    local failed=0

    verify_value net.ipv4.ip_forward "$IPV4" || failed=1
    verify_value net.ipv6.conf.all.forwarding "$IPV6" || failed=1
    verify_value net.ipv4.conf.all.rp_filter 0 || failed=1
    verify_value net.ipv4.conf.default.rp_filter 0 || failed=1

    if [[ "$BBR" == 1 ]]; then
        verify_value net.core.default_qdisc fq || failed=1
        verify_value net.ipv4.tcp_congestion_control bbr || failed=1
    fi

    if [[ "$TUNING" == 1 ]]; then
        verify_value net.core.rmem_default 16777216 || failed=1
        verify_value net.core.rmem_max 33554432 || failed=1
        verify_value net.core.wmem_max 16777216 || failed=1
        verify_value net.core.netdev_max_backlog 16384 || failed=1
        verify_value net.core.somaxconn 4096 || failed=1
        verify_value net.ipv4.tcp_max_syn_backlog 8192 || failed=1
        verify_value net.netfilter.nf_conntrack_max 262144 || failed=1
        verify_value fs.file-max 1048576 || failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        echo
        echo "部分参数验证失败。"
        echo "配置未启用 immutable 保护。"
        echo "备份位置：$BACKUP_DIR"
        return 1
    fi

    lock_config

    mkdir -p "$STATE"

    cat > "$STATE/settings" <<EOF
IPV4=$IPV4
IPV6=$IPV6
BBR=$BBR
TUNING=$TUNING
BACKUP_DIR=$BACKUP_DIR
EOF

    echo
    echo "配置安装成功。"
    echo "配置文件：$CONFIG"
    echo "备份目录：$BACKUP_DIR"
}

# ----------------------------------------------------------
# 修改转发选项
# ----------------------------------------------------------

modify_forwarding() {
    if [[ ! -f "$STATE/settings" ]]; then
        echo "请先安装优化配置。"
        return
    fi

    source "$STATE/settings"

    echo
    echo "修改 IPv4 转发："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择：" choice

    case "$choice" in
        1) IPV4=1 ;;
        2) IPV4=0 ;;
        *) echo "无效选择"; return ;;
    esac

    echo
    echo "修改 IPv6 转发："
    echo "1. 开启"
    echo "2. 关闭"
    read -r -p "请选择：" choice

    case "$choice" in
        1) IPV6=1 ;;
        2) IPV6=0 ;;
        *) echo "无效选择"; return ;;
    esac

    echo
    read -r -p "输入 YES 确认修改：" confirm
    [[ "$confirm" == "YES" ]] || return

    create_backup >/dev/null
    unlock_config

    generate_config "$IPV4" "$IPV6" "$BBR" "$TUNING"

    sysctl --system

    if verify_value net.ipv4.ip_forward "$IPV4" &&
       verify_value net.ipv6.conf.all.forwarding "$IPV6"; then

        lock_config

        cat > "$STATE/settings" <<EOF
IPV4=$IPV4
IPV6=$IPV6
BBR=$BBR
TUNING=$TUNING
BACKUP_DIR=$BACKUP_DIR
EOF

        echo "转发设置修改完成。"
    else
        echo "验证失败，请使用备份恢复。"
    fi
}

# ----------------------------------------------------------
# 恢复备份
# ----------------------------------------------------------

restore_backup() {
    echo
    echo "可用备份："

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        echo "没有备份。"
        return
    fi

    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort

    read -r -p "请输入要恢复的备份目录完整路径：" selected

    [[ -d "$selected/files" ]] || {
        echo "备份目录无效。"
        return
    }

    read -r -p "输入 YES 确认恢复：" confirm
    [[ "$confirm" == "YES" ]] || return

    unlock_config

    # 删除当前由本脚本创建的配置
    rm -f "$CONFIG"

    # 恢复备份文件
    cp -a "$selected/files/." /

    sysctl --system

    echo "备份恢复操作完成。"
    echo "注意：如果备份中包含原有配置，请检查实际生效参数。"
}

# ----------------------------------------------------------
# 卸载脚本配置
# ----------------------------------------------------------

uninstall_config() {
    echo
    echo "此操作将删除本脚本创建的配置，并尝试恢复最近一次安装前备份。"
    read -r -p "输入 YES 确认卸载：" confirm

    [[ "$confirm" == "YES" ]] || return

    if [[ -f "$STATE/settings" ]]; then
        source "$STATE/settings"
    fi

    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR/files" ]]; then
        unlock_config
        rm -f "$CONFIG"
        cp -a "$BACKUP_DIR/files/." /
        sysctl --system
    else
        echo "未找到安装前备份，无法安全恢复旧配置。"
        echo "保留当前配置，不执行删除。"
        return
    fi

    rm -rf "$STATE"

    echo "卸载完成。"
    echo "未卸载任何软件包。"
}

# ----------------------------------------------------------
# 主菜单
# ----------------------------------------------------------

main_menu() {
    while true; do
        clear

        echo "========================================"
        echo "       Debian 13 旁路由优化工具"
        echo "========================================"
        echo
        echo "  1. 安装网络优化配置"
        echo "  2. 查看当前网络参数"
        echo "  3. 修改 IPv4 / IPv6 转发设置"
        echo "  4. 解除配置文件保护"
        echo "  5. 重新启用配置文件保护"
        echo "  6. 恢复安装前备份"
        echo "  7. 卸载本脚本配置"
        echo "  0. 退出"
        echo
        read -r -p "请选择：" choice

        case "$choice" in
            1) install_config ;;
            2) show_status ;;
            3) modify_forwarding ;;
            4)
                unlock_config
                echo "已尝试解除保护。"
                ;;
            5)
                lock_config
                echo "已尝试启用保护。"
                ;;
            6) restore_backup ;;
            7) uninstall_config ;;
            0) exit 0 ;;
            *) echo "无效选择。" ;;
        esac

        echo
        read -r -p "按回车返回菜单……" _
    done
}

# ----------------------------------------------------------
# 启动
# ----------------------------------------------------------

check_system
main_menu
