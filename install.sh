#!/usr/bin/env bash
# ============================================================================
#  vps-deploy · 一键部署代理栈
#  REALITY(443/TCP) + Hysteria2(8443/UDP) + TUIC(8444/UDP) + CF-VLESS(CDN 兜底)
#  附带：订阅服务、BBR 调优、可选 SSH 加固
#
#  用法：
#    bash install.sh                     # 完整安装
#    bash install.sh --harden            # 完整安装 + SSH 加固
#    bash install.sh --no-tunnel         # 不建 Cloudflare 隧道（CF-VLESS 跳过）
#    bash install.sh --uninstall         # 卸载预览
#    bash install.sh --uninstall --yes   # 确认卸载
#
#  幂等：重复执行会复用 /root/vps-nodes.json 里已有的凭据，不会把设备踢下线
#  支持：Debian 11/12 · Ubuntu 20.04/22.04/24.04 · amd64 / arm64
#  所有路径/端口/单元名均可用环境变量覆盖（见下方「可调参数」）
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 可调参数
: "${SINGBOX_VER:=1.14.4}"
: "${XRAY_VER:=25.3.6}"          # 必须锁 25.x：26.x 的 REALITY 与 mihomo 客户端不兼容
: "${CFD_VER:=2026.11.0}"
: "${HY2_PORT:=8443}"
: "${TUIC_PORT:=8444}"
: "${REALITY_PORT:=443}"
: "${CF_WS_PORT:=18889}"
: "${SUB_PORT:=18890}"
: "${HY2_SNI:=www.bing.com}"
: "${REALITY_SNI:=www.cloudflare.com}"
: "${SB_DIR:=/etc/sb2}"
: "${XRAY_DIR:=/usr/local/etc/xray}"
: "${SUB_ROOT:=/var/www/sub}"
: "${CRED_FILE:=/root/vps-nodes.json}"
: "${CF_VLESS_METRICS:=20243}"
: "${CF_SUB_METRICS:=20244}"
: "${SB_UNIT:=sb2}"
: "${XRAY_UNIT:=xray}"
: "${CF_VLESS_UNIT:=cf-vless-tunnel}"
: "${CF_SUB_UNIT:=cf-sub-tunnel}"
: "${NGINX_SITE:=sub}"
: "${SUB_BUILDER:=/usr/local/bin/sub-build.py}"
: "${SUB_SERVICE:=sub-regen.service}"
: "${SUB_TIMER:=sub-regen.timer}"
: "${ENABLE_TUNNEL:=1}"
: "${ENABLE_HARDEN:=0}"
: "${DO_UNINSTALL:=0}"
: "${DO_YES:=0}"

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then
  C_R=$'\033[0m'; C_B=$'\033[1;36m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_E=$'\033[1;31m'
else
  C_R=''; C_B=''; C_G=''; C_Y=''; C_E=''
fi
step() { echo; echo "${C_B}==> $*${C_R}"; }
ok()   { echo "    ${C_G}✓${C_R} $*"; }
warn() { echo "    ${C_Y}!${C_R} $*"; }
die()  { echo "${C_E}✗ $*${C_R}" >&2; exit 1; }

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    --harden)    ENABLE_HARDEN=1 ;;
    --no-tunnel) ENABLE_TUNNEL=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --yes|-y)    DO_YES=1 ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash install.sh）"

# ============================================================================
#  卸载
# ============================================================================
if [ "$DO_UNINSTALL" -eq 1 ]; then
  step "卸载预览"
  echo "    将停止并删除以下服务单元："
  for u in "$SB_UNIT" "$XRAY_UNIT" "$CF_VLESS_UNIT" "$CF_SUB_UNIT" "$SUB_TIMER" "$SUB_SERVICE"; do
    echo "      - $u"
  done
  echo "    将删除目录：$SB_DIR  $XRAY_DIR  $SUB_ROOT"
  echo "    将删除文件：$SUB_BUILDER  /usr/local/bin/sing-box"
  if [ "$DO_YES" -ne 1 ]; then
    echo
    die "确认无误请加 --yes 重跑：bash install.sh --uninstall --yes"
  fi
  step "执行卸载"
  for u in "$SB_UNIT" "$XRAY_UNIT" "$CF_VLESS_UNIT" "$CF_SUB_UNIT" "$SUB_TIMER" "$SUB_SERVICE"; do
    systemctl disable --now "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  rm -f "$SUB_BUILDER" /usr/local/bin/sing-box
  rm -rf "$SB_DIR" "$XRAY_DIR" "$SUB_ROOT"
  rm -f "/etc/nginx/sites-enabled/$NGINX_SITE" "/etc/nginx/sites-available/$NGINX_SITE"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  warn "凭据文件保留在 $CRED_FILE（如要彻底清除请手动删除）"
  ok "卸载完成"
  exit 0
fi

# ============================================================================
#  0. 环境检查
# ============================================================================
step "环境检查"
[ -f /etc/os-release ] || die "无法识别系统"
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ok "系统 ${PRETTY_NAME}" ;;
  *) die "仅支持 Debian / Ubuntu，当前: ${ID:-unknown}" ;;
esac
case "$(uname -m)" in
  x86_64)  GOARCH=amd64; XARCH=64 ;;
  aarch64) GOARCH=arm64; XARCH=arm64-v8a ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac
ok "架构 $(uname -m) → ${GOARCH}"

# ============================================================================
#  1. 依赖
# ============================================================================
step "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip openssl ca-certificates python3 nginx fail2ban iproute2 >/dev/null 2>&1 \
  || die "依赖安装失败"
ok "curl / unzip / openssl / python3 / nginx / fail2ban"

# ============================================================================
#  2. 内核调优（BBR + UDP 缓冲）
# ============================================================================
step "内核调优"
cat > /etc/sysctl.d/99-vps-deploy.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.ip_local_port_range=10240 65000
fs.file-max=1048576
SYSCTL
sysctl --system >/dev/null 2>&1 || true
if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ]; then
  ok "BBR 已启用"
else
  warn "BBR 未生效（内核可能不支持，不影响使用）"
fi

# ============================================================================
#  3. 凭据（幂等：已有则复用）
# ============================================================================
step "生成/复用凭据"
python3 - "$CRED_FILE" <<'PYGEN'
import json, os, secrets, sys, uuid
p = sys.argv[1]
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {}

def need(k, fn):
    if not d.get(k):
        d[k] = fn()
    return d[k]

need("hy2_pw",       lambda: secrets.token_hex(16))
need("hy2_obfs",     lambda: secrets.token_hex(12))
need("tuic_uuid",    lambda: str(uuid.uuid4()))
need("tuic_pw",      lambda: secrets.token_hex(16))
need("cf_uuid",      lambda: str(uuid.uuid4()))
need("reality_uuid", lambda: str(uuid.uuid4()))
need("reality_sid",  lambda: secrets.token_hex(8))
need("sub_token",    lambda: secrets.token_hex(20))
d["cf_path"] = "/%s-vless-cdn" % d["cf_uuid"]

json.dump(d, open(p, "w"), indent=1)
os.chmod(p, 0o600)
print("    凭据文件: %s" % p)
PYGEN
ok "凭据就绪"

# ============================================================================
#  4. Hysteria2 + TUIC + VLESS-WS（sing-box）
# ============================================================================
step "部署 sing-box（HY2 ${HY2_PORT} / TUIC ${TUIC_PORT} / WS ${CF_WS_PORT}）"
if [ ! -x /usr/local/bin/sing-box ] || ! /usr/local/bin/sing-box version 2>/dev/null | grep -q "$SINGBOX_VER"; then
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${GOARCH}.tar.gz"
  TMP=$(mktemp -d)
  curl -fsSL --retry 3 --connect-timeout 15 "$SB_URL" -o "$TMP/sb.tgz" \
    || die "sing-box 下载失败: $SB_URL"
  tar xzf "$TMP/sb.tgz" -C "$TMP"
  install -m 755 "$TMP/sing-box-${SINGBOX_VER}-linux-${GOARCH}/sing-box" /usr/local/bin/sing-box
  rm -rf "$TMP"
  ok "sing-box $(/usr/local/bin/sing-box version | head -1 | awk '{print $3}')"
else
  ok "sing-box 已存在，跳过下载"
fi

mkdir -p "$SB_DIR/cert"
if [ ! -f "$SB_DIR/cert/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes -keyout "$SB_DIR/cert/key.pem" -out "$SB_DIR/cert/cert.pem" \
    -subj "/CN=${HY2_SNI}" -addext "subjectAltName=DNS:${HY2_SNI}" 2>/dev/null \
    || die "自签证书生成失败"
  chmod 600 "$SB_DIR/cert/key.pem"
  ok "自签证书（CN=${HY2_SNI}）"
fi

python3 - "$CRED_FILE" "$SB_DIR/config.json" "$HY2_PORT" "$TUIC_PORT" "$CF_WS_PORT" "$SB_DIR" <<'PYCFG'
import json, sys
cred, out, hy2p, tuicp, wsp, sbd = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                                    int(sys.argv[4]), int(sys.argv[5]), sys.argv[6])
d = json.load(open(cred))
cert = sbd + "/cert/cert.pem"
key = sbd + "/cert/key.pem"
cfg = {
  "log": {"level": "warn", "timestamp": True},
  "inbounds": [
    {"type": "hysteria2", "tag": "hy2-%d" % hy2p, "listen": "::", "listen_port": hy2p,
     "users": [{"password": d["hy2_pw"]}],
     "obfs": {"type": "salamander", "password": d["hy2_obfs"]},
     "tls": {"enabled": True, "alpn": ["h3"],
             "certificate_path": cert, "key_path": key}},
    {"type": "tuic", "tag": "tuic-%d" % tuicp, "listen": "::", "listen_port": tuicp,
     "users": [{"uuid": d["tuic_uuid"], "password": d["tuic_pw"]}],
     "congestion_control": "bbr", "auth_timeout": "3s", "zero_rtt_handshake": False,
     "tls": {"enabled": True, "alpn": ["h3"],
             "certificate_path": cert, "key_path": key}},
    {"type": "vless", "tag": "cf-ws-%d" % wsp, "listen": "127.0.0.1", "listen_port": wsp,
     "users": [{"uuid": d["cf_uuid"]}],
     "transport": {"type": "ws", "path": d["cf_path"]}},
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
}
json.dump(cfg, open(out, "w"), indent=2)
PYCFG

/usr/local/bin/sing-box check -c "$SB_DIR/config.json" || die "sing-box 配置校验失败"
ok "配置校验通过"

cat > "/etc/systemd/system/${SB_UNIT}.service" <<UNIT
[Unit]
Description=sing-box (Hysteria2 + TUIC + VLESS-WS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c ${SB_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$SB_UNIT" >/dev/null 2>&1
systemctl restart "$SB_UNIT"
sleep 1
systemctl is-active --quiet "$SB_UNIT" || die "${SB_UNIT} 启动失败（journalctl -u ${SB_UNIT} 查看）"
ok "${SB_UNIT} 运行中"

# ============================================================================
#  5. Xray REALITY（443/TCP）
# ============================================================================
step "部署 Xray ${XRAY_VER}（REALITY ${REALITY_PORT}/TCP）"
if [ ! -x /usr/local/bin/xray ] || ! /usr/local/bin/xray version 2>/dev/null | grep -q " ${XRAY_VER} "; then
  XR_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XARCH}.zip"
  TMP=$(mktemp -d)
  curl -fsSL --retry 3 --connect-timeout 15 "$XR_URL" -o "$TMP/x.zip" \
    || die "Xray 下载失败: $XR_URL"
  unzip -oq "$TMP/x.zip" xray -d "$TMP"
  install -m 755 "$TMP/xray" /usr/local/bin/xray
  rm -rf "$TMP"
  ok "Xray $(/usr/local/bin/xray version | head -1 | awk '{print $2}')"
else
  ok "Xray 已存在且版本正确，跳过下载"
fi

# REALITY 密钥对（私钥写入凭据文件；公钥由私钥推导，兼容 25.x/26.x 输出格式）
if ! python3 -c "import json,sys;d=json.load(open('$CRED_FILE'));sys.exit(0 if d.get('reality_priv') and d.get('reality_pub') else 1)"; then
  KP=$(/usr/local/bin/xray x25519)
  PRIV=$(printf '%s\n' "$KP" | grep -i 'private' | sed 's/.*: *//')
  PUB=$(printf '%s\n' "$KP" | grep -iE 'public|password' | sed 's/.*: *//')
  [ -n "$PRIV" ] && [ -n "$PUB" ] || die "REALITY 密钥对生成失败"
  python3 - "$CRED_FILE" "$PRIV" "$PUB" <<'PYKP'
import json, sys
p, priv, pub = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p)); d["reality_priv"] = priv; d["reality_pub"] = pub
json.dump(d, open(p, "w"), indent=1)
PYKP
  ok "REALITY 密钥对已生成"
else
  ok "REALITY 密钥对已存在，复用"
fi

mkdir -p "$XRAY_DIR"
python3 - "$CRED_FILE" "$XRAY_DIR/config.json" "$REALITY_PORT" "$REALITY_SNI" <<'PYXR'
import json, sys
cred, out, port, sni = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
d = json.load(open(cred))
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": port, "protocol": "vless",
    "settings": {"clients": [{"id": d["reality_uuid"], "flow": "xtls-rprx-vision"}],
                 "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"dest": "%s:443" % sni, "serverNames": [sni],
                          "privateKey": d["reality_priv"],
                          "shortIds": [d["reality_sid"]]}},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
  }],
  "outbounds": [{"protocol": "freedom"}],
}
json.dump(cfg, open(out, "w"), indent=2)
d["reality_sni"] = sni
json.dump(d, open(cred, "w"), indent=1)
PYXR

/usr/local/bin/xray -test -c "$XRAY_DIR/config.json" >/dev/null 2>&1 || die "Xray 配置校验失败"
ok "配置校验通过"

cat > "/etc/systemd/system/${XRAY_UNIT}.service" <<UNIT
[Unit]
Description=Xray Service (REALITY)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c ${XRAY_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$XRAY_UNIT" >/dev/null 2>&1
systemctl restart "$XRAY_UNIT"
sleep 1
systemctl is-active --quiet "$XRAY_UNIT" || die "${XRAY_UNIT} 启动失败（journalctl -u ${XRAY_UNIT} 查看）"
ok "${XRAY_UNIT} 运行中"

# ============================================================================
#  6. Cloudflare 隧道 + 订阅服务
# ============================================================================
if [ "$ENABLE_TUNNEL" -eq 1 ]; then
  step "部署 Cloudflare 隧道"
  if [ ! -x /usr/local/bin/cloudflared ]; then
    curl -fsSL --retry 3 --connect-timeout 15 \
      "https://github.com/cloudflare/cloudflared/releases/download/${CFD_VER}/cloudflared-linux-${GOARCH}" \
      -o /usr/local/bin/cloudflared || die "cloudflared 下载失败"
    chmod 755 /usr/local/bin/cloudflared
  fi
  ok "cloudflared $(/usr/local/bin/cloudflared --version 2>&1 | awk '{print $3}')"

  cat > "/etc/systemd/system/${CF_VLESS_UNIT}.service" <<UNIT
[Unit]
Description=Cloudflare Quick Tunnel for VLESS-WS (CDN fallback)
After=network-online.target ${SB_UNIT}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:${CF_WS_PORT} --metrics 127.0.0.1:${CF_VLESS_METRICS}
Restart=always
RestartSec=10
StandardOutput=append:/var/log/cf-vless.log
StandardError=append:/var/log/cf-vless.log

[Install]
WantedBy=multi-user.target
UNIT

  cat > "/etc/systemd/system/${CF_SUB_UNIT}.service" <<UNIT
[Unit]
Description=Cloudflare Quick Tunnel for subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://127.0.0.1:${SUB_PORT} --metrics 127.0.0.1:${CF_SUB_METRICS}
Restart=always
RestartSec=5
StandardOutput=append:/var/log/cf-sub.log
StandardError=append:/var/log/cf-sub.log

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "$CF_VLESS_UNIT" "$CF_SUB_UNIT" >/dev/null 2>&1
  systemctl restart "$CF_VLESS_UNIT" "$CF_SUB_UNIT"
  ok "两条隧道已启动"
else
  warn "--no-tunnel：跳过 Cloudflare 隧道（CF-VLESS 节点不可用）"
fi

# ============================================================================
#  7. 订阅服务（nginx + 自动生成）
# ============================================================================
step "部署订阅服务"
SUB_TOKEN=$(python3 -c "import json;print(json.load(open('$CRED_FILE'))['sub_token'])")
mkdir -p "${SUB_ROOT}/${SUB_TOKEN}"
chmod 755 "$SUB_ROOT" "${SUB_ROOT}/${SUB_TOKEN}"

cat > "/etc/nginx/sites-available/${NGINX_SITE}" <<NGINX
server {
    listen 127.0.0.1:${SUB_PORT};
    server_name _;
    root ${SUB_ROOT};
    autoindex off;
    location = / { return 404; }
    location / { try_files \$uri =404; }
}
NGINX
ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"
nginx -t >/dev/null 2>&1 || die "nginx 配置校验失败"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
ok "nginx 监听 127.0.0.1:${SUB_PORT}"

cat > "$SUB_BUILDER" <<'PYSUB'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从服务端实际配置生成订阅（唯一事实来源，杜绝手工复制漂移）"""
import base64, glob, json, os, re, subprocess, urllib.parse

SUB_ROOT = os.environ.get("SUB_ROOT", "/var/www/sub")
HY2_PORT = int(os.environ.get("HY2_PORT", 8443))
TUIC_PORT = int(os.environ.get("TUIC_PORT", 8444))
REALITY_PORT = int(os.environ.get("REALITY_PORT", 443))
CF_PORT = 443
HY2_SNI = os.environ.get("HY2_SNI", "www.bing.com")

G_SEL = "🚀 节点选择"; G_AUTO = "♻️ 自动选择"; G_MAN = "🎯 手动切换"
G_AI = "🤖 AI 专线"; G_MEDIA = "📺 流媒体"; G_TG = "📲 电报"
G_MS = "🔧 微软服务"; G_AD = "🛑 广告拦截"; G_FINAL = "🐟 漏网之鱼"
N_REALITY = "🇺🇸 REALITY-443"; N_HY2 = "🇺🇸 HY2-8443"
N_TUIC = "🇺🇸 TUIC-8444"; N_CF = "☁️ CF-VLESS"


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def server_ip():
    ip = os.environ.get("SERVER_IP")
    if ip:
        return ip
    m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)",
                  sh("ip -4 route get 1.1.1.1 2>/dev/null"))
    if m:
        return m.group(1)
    return sh("curl -4 -s --max-time 5 https://api.ipify.org").strip()


def tunnel_domain(port):
    o = sh("curl -s --max-time 6 http://127.0.0.1:%d/quicktunnel" % port)
    m = re.search(r'"hostname":"([^"]+)"', o)
    return m.group(1) if m else None


def load_creds():
    sb_cfg = os.environ.get("SB_CONFIG", "/etc/sb2/config.json")
    xr_cfg = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
    c = json.load(open(sb_cfg))
    d = {}
    for i in c["inbounds"]:
        if i["type"] == "hysteria2":
            d["hy2_pw"] = i["users"][0]["password"]; d["hy2_obfs"] = i["obfs"]["password"]
        elif i["type"] == "tuic":
            d["tuic_uuid"] = i["users"][0]["uuid"]; d["tuic_pw"] = i["users"][0]["password"]
        elif i["type"] == "vless":
            d["cf_uuid"] = i["users"][0]["uuid"]; d["cf_path"] = i["transport"]["path"]
    x = json.load(open(xr_cfg))
    ib = x["inbounds"][0]; rs = ib["streamSettings"]["realitySettings"]
    d["reality_uuid"] = ib["settings"]["clients"][0]["id"]
    d["reality_priv"] = rs["privateKey"]; d["reality_sid"] = rs["shortIds"][0]
    d["reality_sni"] = rs["serverNames"][0]
    out = sh("xray x25519 -i '%s'" % d["reality_priv"])
    m = re.search(r"(?:Public key|Password \(PublicKey\)):\s*(\S+)", out)
    if not m:
        raise SystemExit("无法推导 REALITY 公钥")
    d["reality_pub"] = m.group(1)
    return d


def proxies(c, dom, ip):
    p = [{"name": N_REALITY, "type": "vless", "server": ip, "port": REALITY_PORT,
          "uuid": c["reality_uuid"], "flow": "xtls-rprx-vision", "tls": True,
          "servername": c["reality_sni"], "client-fingerprint": "chrome",
          "reality-opts": {"public-key": c["reality_pub"], "short-id": c["reality_sid"]},
          "network": "tcp", "udp": True},
         {"name": N_HY2, "type": "hysteria2", "server": ip, "port": HY2_PORT,
          "password": c["hy2_pw"], "obfs": "salamander", "obfs-password": c["hy2_obfs"],
          "sni": HY2_SNI, "skip-cert-verify": True,
          "up": "100 Mbps", "down": "500 Mbps", "udp": True},
         {"name": N_TUIC, "type": "tuic", "server": ip, "port": TUIC_PORT,
          "uuid": c["tuic_uuid"], "password": c["tuic_pw"], "alpn": ["h3"],
          "sni": HY2_SNI, "skip-cert-verify": True, "congestion-controller": "bbr",
          "udp-relay-mode": "native", "udp": True}]
    if dom:
        p.append({"name": N_CF, "type": "vless", "server": dom, "port": CF_PORT,
                  "uuid": c["cf_uuid"], "tls": True, "servername": dom, "network": "ws",
                  "ws-opts": {"path": c["cf_path"], "headers": {"Host": dom}}, "udp": True})
    return p


def groups(has_cf):
    nodes = [N_REALITY, N_HY2, N_TUIC] + ([N_CF] if has_cf else [])
    sel = [G_AUTO, G_MAN, N_REALITY] + ([N_CF] if has_cf else []) + ["DIRECT"]
    return [
        {"name": G_SEL, "type": "select", "proxies": sel},
        {"name": G_AUTO, "type": "url-test", "url": "http://www.gstatic.com/generate_204",
         "interval": 300, "tolerance": 80, "lazy": True, "proxies": nodes},
        {"name": G_MAN, "type": "select", "proxies": nodes},
        {"name": G_AI, "type": "select", "proxies": [G_SEL, G_AUTO, G_MAN]},
        {"name": G_MEDIA, "type": "select", "proxies": [G_SEL, G_AUTO, G_MAN]},
        {"name": G_TG, "type": "select", "proxies": [G_SEL, G_AUTO, G_MAN]},
        {"name": G_MS, "type": "select", "proxies": ["DIRECT", G_SEL, G_AUTO]},
        {"name": G_AD, "type": "select", "proxies": ["REJECT", "DIRECT"]},
        {"name": G_FINAL, "type": "select", "proxies": [G_SEL, G_AUTO, G_MAN]},
    ]


AI_DOMAINS = ["openai.com","chatgpt.com","oaistatic.com","oaiusercontent.com","sora.com",
 "anthropic.com","claude.ai","claudeusercontent.com","gemini.google.com","bard.google.com",
 "aistudio.google.com","generativelanguage.googleapis.com","notebooklm.google.com",
 "perplexity.ai","poe.com","x.ai","grok.com","copilot.microsoft.com","midjourney.com",
 "huggingface.co","hf.co","openrouter.ai","together.ai","replicate.com","elevenlabs.io",
 "suno.ai","suno.com","cursor.com","cursor.sh","codeium.com","windsurf.com",
 "meta.ai","muse.ai","metaaivm.com","meta.com","facebook.com","fbcdn.net","instagram.com",
 "cdninstagram.com","whatsapp.com","whatsapp.net","threads.net"]

MEDIA_DOMAINS = ["youtube.com","youtu.be","googlevideo.com","ytimg.com","ggpht.com",
 "youtube-nocookie.com","netflix.com","nflxvideo.net","nflximg.net","nflxext.com","nflxso.net",
 "fast.com","disneyplus.com","dssott.com","bamgrid.com","hbomax.com","hbomaxcdn.com","max.com",
 "primevideo.com","aiv-cdn.net","amazonvideo.com","hulu.com","hulustream.com","crunchyroll.com",
 "crunchyrollsvc.com","spotify.com","scdn.co","spotifycdn.com","tiktok.com","tiktokcdn.com",
 "tiktokv.com","byteoversea.com","ibytedtos.com","twitch.tv","ttvnw.net","jtvnw.net",
 "soundcloud.com","sndcdn.com","deezer.com"]

MS_DOMAINS = ["microsoft.com","microsoftonline.com","microsoftstore.com","microsoftazure.com",
 "msftauth.net","msauth.net","msftconnecttest.com","msftncsi.com","windowsupdate.com",
 "windows.com","windows.net","live.com","msn.com","office.com","office365.com",
 "sharepoint.com","onedrive.com","azure.com","azureedge.net","bing.com","bing.net",
 "visualstudio.com","xbox.com","xboxlive.com","skype.com"]

RULE_SETS = [("private","domain","private.txt"),("reject","domain","reject.txt"),
 ("icloud","domain","icloud.txt"),("apple","domain","apple.txt"),
 ("google","domain","google.txt"),("proxy","domain","proxy.txt"),
 ("direct","domain","direct.txt"),("applications","classical","applications.txt"),
 ("telegramcidr","ipcidr","telegramcidr.txt"),("lancidr","ipcidr","lancidr.txt"),
 ("cncidr","ipcidr","cncidr.txt")]


def rules(ip):
    r = ["PROCESS-NAME,Clash Verge,DIRECT","PROCESS-NAME,clash-verge,DIRECT",
         "PROCESS-NAME,Muse,"+G_AI,"PROCESS-PATH,/Applications/Muse.app/Contents/MacOS/Muse,"+G_AI,
         "PROCESS-NAME,Telegram,"+G_TG,"PROCESS-NAME,Telegram Desktop,"+G_TG,
         "IP-CIDR,%s/32,DIRECT,no-resolve" % ip,
         "DOMAIN,clash.razord.top,DIRECT","DOMAIN,yacd.haishan.me,DIRECT",
         "RULE-SET,private,DIRECT","RULE-SET,lancidr,DIRECT","GEOIP,LAN,DIRECT",
         "RULE-SET,reject,"+G_AD,"RULE-SET,applications,DIRECT"]
    r += ["DOMAIN-SUFFIX,%s,%s" % (d, G_AI) for d in AI_DOMAINS]
    r += ["DOMAIN-SUFFIX,%s,%s" % (d, G_MEDIA) for d in MEDIA_DOMAINS]
    r += ["RULE-SET,telegramcidr,"+G_TG, "RULE-SET,icloud,"+G_SEL]
    r += ["DOMAIN-SUFFIX,%s,%s" % (d, G_MS) for d in MS_DOMAINS]
    r += ["RULE-SET,apple,DIRECT","RULE-SET,google,"+G_SEL,"RULE-SET,proxy,"+G_SEL,
          "RULE-SET,direct,DIRECT","RULE-SET,cncidr,DIRECT","GEOIP,CN,DIRECT","MATCH,"+G_FINAL]
    return r


def dns():
    return {"enable": True, "ipv6": False, "enhanced-mode": "fake-ip",
      "fake-ip-range": "198.18.0.1/16", "use-hosts": True, "respect-rules": True,
      "default-nameserver": ["223.5.5.5","119.29.29.29"],
      "nameserver": ["https://dns.alidns.com/dns-query","https://doh.pub/dns-query"],
      "proxy-server-nameserver": ["https://dns.alidns.com/dns-query","https://doh.pub/dns-query"],
      "nameserver-policy": {
        "geosite:cn,private": ["https://dns.alidns.com/dns-query","https://doh.pub/dns-query"],
        "geosite:geolocation-!cn": ["https://1.1.1.1/dns-query#"+G_SEL,
                                    "https://dns.google/dns-query#"+G_SEL]},
      "fake-ip-filter": ["*.lan","*.local","*.localdomain","*.arpa","+.lan","+.local",
        "localhost.ptlogin2.qq.com","localhost.*","+.msftconnecttest.com","+.msftncsi.com",
        "dns.msftncsi.com","time.*.com","ntp.*.com","+.pool.ntp.org","+.market.xiaomi.com",
        "+.srv.nintendo.net","+.stun.playstation.net","*.battlenet.com.cn","xbox.*.microsoft.com",
        "+.xboxlive.com","+.push.apple.com","+.push-apple.com.akadns.net","lens.l.google.com",
        "music.163.com","+.126.net","+.work.weixin.qq.com","+.wecom.qq.com","+.meta.ai",
        "+.meta.com","+.muse.ai","+.metaaivm.com","+.facebook.com","+.instagram.com",
        "+.whatsapp.com","+.whatsapp.net"]}


def sniffer():
    return {"enable": True, "override-destination": True, "force-dns-mapping": True,
      "parse-pure-ip": True,
      "sniff": {"HTTP": {"ports": [80,"8080-8880"], "override-destination": True},
                "TLS": {"ports": [443,8443], "override-destination": True},
                "QUIC": {"ports": [443,8443], "override-destination": True}}}


def config(c, dom, ip):
    has_cf = bool(dom)
    return {"mode": "rule", "mixed-port": 7890, "allow-lan": False, "log-level": "warning",
      "ipv6": False, "unified-delay": True, "tcp-concurrent": True, "find-process-mode": "strict",
      "sniffer": sniffer(), "dns": dns(),
      "proxies": proxies(c, dom, ip), "proxy-groups": groups(has_cf),
      "rule-providers": {n: {"type": "http", "behavior": b,
          "url": "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/"+f,
          "path": "./ruleset/%s.yaml" % n, "interval": 86400} for n,b,f in RULE_SETS},
      "rules": rules(ip)}


def uris(c, dom, ip):
    q = urllib.parse.quote
    out = ["hysteria2://%s@%s:%d/?sni=%s&obfs=salamander&obfs-password=%s&insecure=1#%s"
           % (c["hy2_pw"], ip, HY2_PORT, HY2_SNI, c["hy2_obfs"], N_HY2),
           "tuic://%s:%s@%s:%d/?congestion_control=bbr&alpn=h3&sni=%s&allow_insecure=1#%s"
           % (c["tuic_uuid"], c["tuic_pw"], ip, TUIC_PORT, HY2_SNI, N_TUIC),
           "vless://%s@%s:%d/?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s"
           "&type=tcp&flow=xtls-rprx-vision#%s"
           % (c["reality_uuid"], ip, REALITY_PORT, c["reality_sni"],
              c["reality_pub"], c["reality_sid"], N_REALITY)]
    if dom:
        out.append("vless://%s@%s:%d/?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s"
                   % (c["cf_uuid"], dom, CF_PORT, dom, dom, q(c["cf_path"], safe=""), N_CF))
    return out


def to_yaml(obj, ind=0):
    sp = "  " * ind
    if isinstance(obj, dict):
        lines = []
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                lines.append("%s%s:" % (sp, json.dumps(k, ensure_ascii=False) if re.search(r"[^\w\-.]", str(k)) else k))
                lines.append(to_yaml(v, ind + 1))
            elif isinstance(v, (dict, list)):
                lines.append("%s%s: %s" % (sp, k, "{}" if isinstance(v, dict) else "[]"))
            else:
                lines.append("%s%s: %s" % (sp, k, scalar(v)))
        return "\n".join(lines)
    if isinstance(obj, list):
        lines = []
        for v in obj:
            if isinstance(v, (dict, list)) and v:
                body = to_yaml(v, ind + 1).split("\n")
                body[0] = sp + "- " + body[0].strip()
                lines.append("\n".join(body))
            else:
                lines.append("%s- %s" % (sp, scalar(v)))
        return "\n".join(lines)
    return sp + scalar(obj)


def scalar(v):
    if v is True: return "true"
    if v is False: return "false"
    if v is None: return "null"
    if isinstance(v, int): return str(v)
    s = str(v)
    if s == "" or re.search(r"[:#\[\]{}&*!|>'\"%@`]", s) or s.lower() in ("true","false","null","yes","no"):
        return json.dumps(s, ensure_ascii=False)
    return s


def main():
    ip = server_ip()
    if not ip:
        raise SystemExit("无法探测服务器公网 IP，可设 SERVER_IP 环境变量")
    dom = tunnel_domain(int(os.environ.get("CF_VLESS_METRICS", 20243)))
    c = load_creds()
    text = "---\n" + to_yaml(config(c, dom, ip)) + "\n"
    b64 = base64.b64encode("\n".join(uris(c, dom, ip)).encode()).decode()
    dirs = [d for d in glob.glob(SUB_ROOT + "/*") if os.path.isdir(d)]
    if not dirs:
        raise SystemExit("找不到订阅目录 %s" % SUB_ROOT)
    for d in dirs:
        open(os.path.join(d, "clash.yaml"), "w", encoding="utf-8").write(text)
        open(os.path.join(d, "base64.txt"), "w", encoding="utf-8").write(b64)
    print("ip=%s domain=%s 节点=%d 目录=%d" % (ip, dom or "(无隧道)", len(uris(c, dom, ip)), len(dirs)))


if __name__ == "__main__":
    main()
PYSUB
chmod 755 "$SUB_BUILDER"

cat > "/etc/systemd/system/${SUB_SERVICE}" <<UNIT
[Unit]
Description=Rebuild subscription from server config

[Service]
Type=oneshot
Environment=SB_CONFIG=${SB_DIR}/config.json
Environment=XRAY_CONFIG=${XRAY_DIR}/config.json
Environment=SUB_ROOT=${SUB_ROOT}
Environment=HY2_PORT=${HY2_PORT}
Environment=TUIC_PORT=${TUIC_PORT}
Environment=REALITY_PORT=${REALITY_PORT}
Environment=HY2_SNI=${HY2_SNI}
Environment=CF_VLESS_METRICS=${CF_VLESS_METRICS}
ExecStart=${SUB_BUILDER}
UNIT

cat > "/etc/systemd/system/${SUB_TIMER}" <<UNIT
[Unit]
Description=Rebuild subscription every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now "$SUB_TIMER" >/dev/null 2>&1
ok "订阅定时重建已启用"

# ============================================================================
#  8. SSH 加固（可选）
# ============================================================================
if [ "$ENABLE_HARDEN" -eq 1 ]; then
  step "SSH 加固"
  if [ ! -s /root/.ssh/authorized_keys ]; then
    warn "没有公钥，跳过（先装公钥再加 --harden）"
  else
    printf 'PubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-pubkey.conf
    sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    if sshd -T 2>/dev/null | grep -q '^pubkeyauthentication yes'; then
      ok "公钥认证已开启"
      printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
        > /etc/ssh/sshd_config.d/99-nopass.conf
      sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null) \
        && ok "密码登录已关闭"
    else
      warn "公钥认证未生效，保留密码登录（避免锁死）"
    fi
    CLIENT_IP="${SSH_CLIENT%% *}"
    if [ -n "${CLIENT_IP:-}" ]; then
      cat > /etc/fail2ban/jail.d/sshd.local <<F2B
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = 127.0.0.1/8 ::1 ${CLIENT_IP}
F2B
      systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban 已启用（白名单 ${CLIENT_IP}）"
    fi
  fi
fi

# ============================================================================
#  9. 生成订阅 + 汇总
# ============================================================================
step "生成订阅"
env SB_CONFIG="${SB_DIR}/config.json" XRAY_CONFIG="${XRAY_DIR}/config.json" \
    SUB_ROOT="${SUB_ROOT}" HY2_PORT="${HY2_PORT}" TUIC_PORT="${TUIC_PORT}" \
    REALITY_PORT="${REALITY_PORT}" HY2_SNI="${HY2_SNI}" \
    CF_VLESS_METRICS="${CF_VLESS_METRICS}" \
    "$SUB_BUILDER" || warn "订阅首次生成失败（隧道可能还没就绪，10 分钟内会自动重试）"

step "完成"
python3 - "$CRED_FILE" "$SUB_ROOT" "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" <<'PYSUM'
import json, sys, os, re
cred, sub_root, rp, hy2p, tuicp = sys.argv[1:6]
d = json.load(open(cred))
m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)",
              os.popen("ip -4 route get 1.1.1.1 2>/dev/null").read())
ip = m.group(1) if m else "?"
print("""
  服务器: %s
  ┌────────────────────────────────────────────────────────────┐
  │ REALITY    %s/TCP   XTLS-Vision  伪装 %s
  │ Hysteria2  %s/UDP   salamander
  │ TUIC v5    %s/UDP   BBR
  │ CF-VLESS   443/TCP  Cloudflare 隧道（IP 被封时的兜底）
  └────────────────────────────────────────────────────────────┘
  凭据文件: %s  (含全部密钥，勿外传)
""" % (ip, rp, d.get("reality_sni", "?"), hy2p, tuicp, cred))
print("  订阅目录: %s/%s" % (sub_root, d["sub_token"]))
print("  订阅地址（隧道域名见下方）:")
print("    https://<隧道域名>/%s/clash.yaml" % d["sub_token"])
print("    https://<隧道域名>/%s/base64.txt" % d["sub_token"])
print("""
  下一步：
    1) 打开 Clash 导入上面的 clash.yaml（手机可用 base64.txt）
    2) 想加 SSH 加固就重跑：bash install.sh --harden
""")
PYSUM

if [ "$ENABLE_TUNNEL" -eq 1 ]; then
  step "等待隧道就绪"
  for i in $(seq 1 20); do
    SUBDOM=$(curl -s --max-time 3 "http://127.0.0.1:${CF_SUB_METRICS}/quicktunnel" 2>/dev/null \
             | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p')
    [ -n "${SUBDOM:-}" ] && break
    sleep 3
  done
  if [ -n "${SUBDOM:-}" ]; then
    TOKEN=$(python3 -c "import json;print(json.load(open('$CRED_FILE'))['sub_token'])")
    env SB_CONFIG="${SB_DIR}/config.json" XRAY_CONFIG="${XRAY_DIR}/config.json" \
        SUB_ROOT="${SUB_ROOT}" HY2_PORT="${HY2_PORT}" TUIC_PORT="${TUIC_PORT}" \
        REALITY_PORT="${REALITY_PORT}" HY2_SNI="${HY2_SNI}" \
        "$SUB_BUILDER" >/dev/null 2>&1 || true
    ok "订阅已就绪"
    echo
    echo "  ${C_G}clash.yaml${C_R}  https://${SUBDOM}/${TOKEN}/clash.yaml"
    echo "  ${C_G}base64.txt${C_R}  https://${SUBDOM}/${TOKEN}/base64.txt"
    echo
    echo "  ${C_Y}注意${C_R}：quick tunnel 域名在隧道重启后会变，变了重跑 sub-build.py 即可"
  else
    warn "隧道域名暂未取到，稍后执行 sub-build.py 会补上"
  fi
fi
