# vps-deploy

一条命令把一台干净的 VPS 变成可用的代理节点。适用于 Debian 11/12、Ubuntu 20.04/22.04/24.04，amd64 / arm64。

## 一条命令

在 VPS 上用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chrisppooee-ux/vps-deploy/main/install.sh)
```

或者从本地机器远程驱动（新机器只开了密码登录也能用）：

```bash
ssh root@<新VPS的IP> 'bash <(curl -fsSL https://raw.githubusercontent.com/chrisppooee-ux/vps-deploy/main/install.sh)'
```

跑完会打印一个订阅地址，复制到 Clash 里导入即可。

## 装完得到什么

| 协议 | 端口 | 说明 |
|---|---|---|
| VLESS-REALITY | 443/TCP | XTLS-Vision，伪装访问 `www.cloudflare.com`，抗封锁最强 |
| Hysteria2 | 8443/UDP | salamander 混淆，弱网表现好 |
| TUIC v5 | 8444/UDP | BBR 拥塞控制 |
| VLESS-WS | 443/TCP（Cloudflare） | 走 CDN，IP 被墙时的兜底通道，共下发 3 个：域名版 + 2 个写死 CF 边缘 IP 的版本 |

外加：

- **订阅服务**：nginx + 定时任务，从服务端配置自动生成 `clash.yaml` 和 `base64.txt`。对外提供两个入口：`http://<IP>:18890/<token>/clash.yaml`（直连 IP，稳定）和 Cloudflare 隧道的 HTTPS 地址（备用）
- **系统调优**：BBR、16MB UDP 缓冲、文件句柄上限
- **可选 SSH 加固**：`--harden` 打开公钥认证、关闭密码登录、fail2ban 白名单

所有凭据写在 `/root/vps-nodes.json`，权限 600。

## 参数

```bash
bash install.sh --harden          # 同时做 SSH 加固（需已装公钥）
bash install.sh --no-tunnel       # 不建 Cloudflare 隧道，跳过 CF-VLESS
bash install.sh --uninstall       # 卸载预览（列出会删什么）
bash install.sh --uninstall --yes # 确认卸载
```

路径、端口、systemd 单元名都可以用环境变量覆盖，例如同一台机器再跑一套测试栈：

```bash
SB_DIR=/etc/sb-test XRAY_DIR=/usr/local/etc/xray-test \
HY2_PORT=18443 TUIC_PORT=18444 REALITY_PORT=24443 \
SUB_PORT=18898 SUB_ROOT=/var/www/sub-test CRED_FILE=/root/vps-test.json \
SB_UNIT=sbtest XRAY_UNIT=xraytest NGINX_SITE=subtest \
CF_VLESS_UNIT=cf-vless-test CF_SUB_UNIT=cf-sub-test \
SUB_BUILDER=/usr/local/bin/sub-build-test.py \
SUB_SERVICE=subtest-regen.service SUB_TIMER=subtest-regen.timer \
ENABLE_TUNNEL=0 bash install.sh
```

> 覆盖路径时**记得连单元名一起覆盖**，否则卸载会误删同名服务。

## 幂等

重复执行是安全的：`/root/vps-nodes.json` 存在时复用已有凭据，只补齐缺失项。升级组件、改配置、重装服务都可以直接重跑，不会把已连上的设备踢下线。

## 客户端

- **Clash Verge / Clash Meta（Windows、安卓）**：导入订阅里的 `clash.yaml`，规则、策略组、DNS 防泄漏全都现成
- **Shadowrocket / Stash（iOS）**：导入 `base64.txt`
- 只想手填单个节点：`base64.txt` 解码后是标准 URI

## 已知坑

**REALITY 认证失败**——服务端 Xray 必须锁在 25.x。26.x 改了 REALITY 握手（引入 X25519MLKEM768 后量子混合密钥交换），mihomo 的 REALITY 客户端跟不上，表现是客户端日志 `REALITY Authentication: false`、连接超时。脚本默认装 `25.3.6`，别手动升级。

**隧道域名会变，旧域名直接 NXDOMAIN**——Cloudflare quick tunnel 是临时的，隧道进程一重启域名就换，旧域名立刻变成 `NXDOMAIN`。拿旧链接去导入会失败，报错容易被误读成"临时域名不可用"。`sub-build.py` 每 10 分钟从 `cloudflared` 的 metrics 接口读取当前域名重写订阅，所以**订阅内容**永远是最新的；问题只在"订阅 URL 本身"会不会变——这也是订阅默认走 IP 直连的原因。

**兜底节点不能依赖客户端 DNS**——`☁️ CF-VLESS` 的 `server` 是隧道域名，客户端必须自己解析它；如果客户端 DNS 配置有问题（fake-ip、解析器被污染、离线），兜底节点就先于隧道挂掉，等于没有兜底。所以生成器会在服务端把域名解析成 CF 边缘 IP，额外下发 `☁️ CF-优选1/2`：`server` 写 IP，`servername` 和 WS 的 `Host` 仍是域名。客户端不做任何解析，TLS 的 SNI 和 Host 头依然正确，Cloudflare 照样按域名路由。边缘 IP 每次重生成时重新解析，不会写死过期。

**实测数据（2026-11，广东电信）**：`trycloudflare.com` 在国内**能**正常解析（腾讯/阿里/114 的 UDP 53 与 DoH 都返回 `104.16.230.132` / `104.16.231.132`），直连 CF 边缘 TCP 186ms、TLS 握手成功、WS 握手返回 `101 Switching Protocols`。所以这条路是通的，别再去怀疑 DNS 污染。

**`trycloudflare.com` 与订阅导入**——客户端导入订阅时通常还没连上任何节点，是**直连**去拉 `clash.yaml` 的。所以 nginx 监听 `0.0.0.0:18890`，用 IP 直连地址导入，全程不碰 DNS。代价是该入口是明文 HTTP，token 在路径里（40 位十六进制，不可爆破）。同一个目录下还会生成 `current.txt`，从 IP 直连地址随时能查到当前的隧道域名和最新订阅链接——隧道域名变了也不至于失联。

**自签证书**——HY2 和 TUIC 用的是脚本现场生成的自签证书，客户端配置里 `skip-cert-verify: true`，属于预期行为。

**测试节点时不要走自己的 TUN**——在本机测节点，如果 Clash 的 TUN 开着，测试进程的拨号会进 TUN 被二次中转，TLS sniffing 会破坏 REALITY 的 ClientHello，表现为认证失败。测试实例加 `interface-name: en0`（macOS）或对应的物理网卡名可绕开。

## 文件

```
install.sh    全部逻辑，自包含，不依赖其他文件
```

## 卸载

```bash
bash install.sh --uninstall --yes
```

保留 `/root/vps-nodes.json`（里面有凭据，要彻底清除需手动删）。
