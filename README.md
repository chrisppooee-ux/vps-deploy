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
| VLESS-WS | 443/TCP（Cloudflare） | 走 CDN，IP 被墙时的兜底通道 |

外加：

- **订阅服务**：nginx + 定时任务，从服务端配置自动生成 `clash.yaml` 和 `base64.txt`，通过 Cloudflare 隧道对外提供 HTTPS 地址
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

**隧道域名会变**——Cloudflare quick tunnel 是临时的，隧道进程重启后域名就换。换完执行一次 `sub-build.py` 会重写订阅内容，但订阅 URL 本身变了，需要重新分发。想要固定域名，得用 Cloudflare 账号建命名隧道。

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
