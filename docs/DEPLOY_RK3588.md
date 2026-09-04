# CanaryGC 部署指南 — RK3588 (Rockchip)

本指南说明如何在 **RK3588** 开发板上以**生产模式**部署 [CanaryGC](https://github.com/judahpaul16/canarygc)（Web 飞控地面站），使地面站运行在机身侧、通过**串口**连接真实的飞控（ArduPilot / PX4）。

> 已验证硬件/软件基线：
>
> - **SoC**：Rockchip RK3588（aarch64 / arm64，8 核）
> - **OS**：Armbian 26.8（Ubuntu 24.04 noble 用户态）
> - **内核**：`6.1.157-rk3588-ophub`（vendor 6.1 内核，`uname -m` = aarch64）
> - **容器**：docker.io 29.x + Docker Compose v2（`apt` 自带）

原项目默认面向 Raspberry Pi（`contrib/setup.sh`）。RK3588 与其差异集中在三点：**板载串口（ttyS*）、摄像头（无 rpiCamera）、镜像架构（arm64/alpine-musl）**。`contrib/setup-rk3588.sh` 针对这些做了对应处理，其余沿用原项目的 `docker-compose.yml` 与 `production` profile。

---

## 目录

1. [快速开始](#1-快速开始)
2. [前置条件与硬件接线](#2-前置条件与硬件接线)
3. [RK3588 串口（UART）配置](#3-rk3588-串口uart配置)
4. [.env 配置](#4-env-配置)
5. [镜像架构说明](#5-镜像架构说明)
6. [摄像头配置](#6-摄像头配置)
7. [开机自启（systemd）](#7-开机自启systemd)
8. [防火墙与公网访问](#8-防火墙与公网访问)
9. [故障排查](#9-故障排查)

---

## 1. 快速开始

```bash
# 默认 REPO_URL 是原仓库；若是自用 fork，先导出：
export REPO_URL=https://github.com/<你的账号>/canarygc.git

# 完整安装（安装 Docker + 防火墙 + 串口权限）并以生产模式启动
bash -s -- < contrib/setup-rk3588.sh
```

如果 Docker 已装好，只启动应用：

```bash
export REPO_URL=https://github.com/<你的账号>/canarygc.git
bash -s -- --install-only < contrib/setup-rk3588.sh
```

启动后访问：`http://<开发板IP>/`（nginx 已路由到应用，端口 80）。

首次运行数据库为空，请打开 `/register` 创建操作员账号。

本地 SITL 仿真测试（无需真机）：

```bash
bash -s -- --simulation < contrib/setup-rk3588.sh
```

---

## 2. 前置条件与硬件接线

**系统依赖**（`setup-rk3588.sh` 会自动安装）：

```bash
sudo apt-get install -y docker.io docker-compose-v2 ufw wget network-manager
sudo systemctl enable --now docker
```

**飞控接线**（RK3588）：

- **串口接线**：飞控的 TELEM/MAVLink 串口接到 RK3588 的 UART 引脚（TX↔RX、RX↔TX、GND↔GND），波特率按飞控配置（默认 115200，或 921600）。
- **USB 接线（推荐）**：USB-TTL 数传或飞控 USB 口接到 RK3588，会在 `/dev/ttyUSB*` 或 `/dev/ttyACM*` 出现。**USB 路径比板载 UART 更容易**，无需改 overlay。
- 连接后确认设备节点：

  ```bash
  ls -l /dev/ttyS* /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/
  ```

---

## 3. RK3588 串口（UART）配置

**关键差异**：CanaryGC 的 MAVLink 串口 autodetect 固定扫描 `/dev/ttyACM*`、`/dev/ttyAMA0`、`/dev/serial0`、`/dev/ttyUSB*`（见 `src/lib/server/mavlink.ts` 的 `serialCandidates()`），**不包含 RK3588 的板载 `/dev/ttyS*`**。

因此：

1. **优先使用 USB 串口**（出 `/dev/ttyUSB*` 或 `/dev/ttyACM*`，autodetect 可直接找到）。
2. 若必须用 RK3588 板载 UART（`/dev/ttyS*`）：
   - 在 `/boot/armbianEnv.txt` 的 `overlays=` 中启用对应串口，例如：

     ```ini
     overlays=uart4-m2
     ```

     （不同载板串口名称不同，见你的板卡资料；也可用 `armbian-config` → System → Hardware 勾选。）
   - 重启后确认设备出现，然后在 `.env` **显式指定**：

     ```
     MAVLINK_SERIAL_PATH=/dev/ttyS4
     MAVLINK_BAUD=115200
     ```

**串口权限**：`setup-rk3588.sh` 会把当前用户加入 `dialout`、`tty`、`video` 组。容器通过 `docker-compose.yml` 的 `/dev:/dev` 映射与 `device_cgroup_rules`（`c 188:*` ttyUSB、`c 204:*` ttyS、`c 166:*` ttyACM、`c 189:*` usb 等）访问这些节点。**避免占用板载调试串口**（通常也被标成 ttyS 且被系统 console 占用）；用任何串口前先确认未被 getty 抢占：

```bash
# 查看串口是否被 console/getty 占用，占用的请禁用对应 console
systemctl list-units | grep -i getty
# 或临时查看
sudo dmesg | grep tty
```

---

## 4. .env 配置

从 `.env.example` 复制并编辑：

```bash
cp .env.example .env
```

RK3588 生产模式推荐配置：

```dotenv
# ── 端口 ─────────────────────────────────────────────
HTTP_PORT=80
APP_PORT=3000

# ── 串口（飞控）───────────────────────────────────
# 优先用 USB 串口 /dev/ttyUSB0 或 /dev/ttyACM0（autodetect 可识别）
# 若用板载 UART，显式指定（见第 3 节）
MAVLINK_SERIAL_PATH=/dev/ttyUSB0
MAVLINK_BAUD=115200

# ── MAVLink 2 签名（公网必须启用）────────────────
# MAVLINK_SIGNING_KEY=在此填入随机口令
# 也可在网页 Integrations 页填写（存数据库，优先）

# ── 摄像头 ─────────────────────────────────────────
# RK3588 无 rpiCamera；用 V4L2 或 RTSP（见第 6 节）
WEBRTC_SOURCE=publisher
# WEBRTC_SOURCE=rtsp://user:pass@host:554/stream
WEBRTC_RUNONDEMAND=ffmpeg -f v4l2 -framerate 30 -video_size 1280x720 -i /dev/video0 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -f rtsp rtsp://localhost:8554/cam

# ── 空气域 / 地图 / AI（可选）────────────────────
# OPENAIP_API_KEY=
# MAPTILER_KEY=
# AI_API_KEY=
# AI_BASE_URL=
# AI_MODEL=
```

运行 `docker compose --profile production up -d app nginx`（带摄像头则加 `webrtc`）。

---

## 5. 镜像架构说明

CanaryGC 官方生产镜像支持 **linux/amd64 与 linux/arm64**：

```bash
docker pull ghcr.io/judahpaul16/canarygc:latest
```

它基于 `node:26-alpine`（musl libc）。arm64 镜像由其 CI 用 `Dockerfile.prod` 的 **deps 阶段在目标平台 `npm ci`** 构建，因此 `serialport`/`node-datachannel`/`@node-rs/argon2`/`libsql` 都已在 arm64 上就绪：

| 原生依赖 | arm64 可用性 |
| --- | --- |
| `serialport` (`@serialport/bindings-cpp`) | CI 在 arm64 上源码编译通过；无 Alpine prebuilt，但镜像内已内置 |
| `node-datachannel` | ✅ arm64 prebuilt（glibc & musl） |
| `@node-rs/argon2` | ✅ arm64 prebuilt |
| `@libsql/client` | ✅ arm64 prebuilt |

> ⚠️ 不要在 x86 机器上拉取 arm64 后的通用镜像直接 `--platform` 跑；应使用 RK3588 可直接拉取的 arm64 版本。若你的网络无法拉取 ghcr，可在 RK3588 本机用 `Dockerfile.prod` 构建（该板 8 核 / 7.7GB 内存足以 `npm ci` 源码编译 serialport）。

`nginx:alpine` 与 `bluenviron/mediamtx:latest-rpi` 均提供 arm64 变体，RK3588 可直接使用。

---

## 6. 摄像头配置

RK3588 **没有树莓派 CSI 的 `rpiCamera` 源**。代码已支持 `usb`（V4L2）与 `url`（RTSP）两种（见 `src/lib/server/camera-source.ts`），通过 `.env` 的 `WEBRTC_SOURCE` 或**网页 Integrations → Camera** 配置。

- **板载/USB 摄像头（V4L2）**：确认 `/dev/video0` 存在。设 `WEBRTC_SOURCE=publisher` + `WEBRTC_RUNONDEMAND` 指向设备；或在 Integrations 选 `USB camera` 并填 `/dev/video0`。
- **外部 RTSP（IP 摄像头）**：设 `WEBRTC_SOURCE=rtsp://...`，MediaMTX 零转码透传，负载最低。

> **⚠️ MediaMTX API 版本兼容性（上游已知问题，与 RK3588 无关）**
>
> 实测 `bluenviron/mediamtx:latest-rpi` 拉到的当前版本（1.20.1）的 API 路径与 app 代码期望不一致：app 在 Integrations 里保存摄像头源时调 `PATCH /v3/config/paths/patch/cam`（`src/lib/server/mediamtx.ts:20`），而 1.20.1 对该路径返回 404，导致 app 报 `MediaMTX not reachable to apply camera source: fetch failed`（`/v3/config/paths/get/cam` 等端点则返回 200）。此问题在树莓派上同样存在，属上游待修复项。
>
> **Workaround**：直接在 `.env` 设置 `WEBRTC_SOURCE`（经 docker-compose 注入 `MTX_PATHS_CAM_SOURCE`，容器启动时生效，不依赖 PATCH API）：

```dotenv
# 例如接 HDMI-in 或外部 RTSP：
WEBRTC_SOURCE=rtsp://user:pass@host:554/stream
# 或 V4L2 采集：
WEBRTC_SOURCE=publisher
WEBRTC_RUNONDEMAND=ffmpeg -f v4l2 -framerate 30 -video_size 1280x720 -i /dev/video0 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -f rtsp rtsp://localhost:8554/cam
```
然后 `docker compose --profile production up -d webrtc` 重启 webrtc 即可生效。

若暂时不需要视频，启动时可省略 `webrtc` 服务。

---

## 7. 开机自启（systemd）

`docker-compose.yml` 的服务均带 `restart: always`，Docker 开机自启后容器会自动拉起。确保 Docker 服务自启：

```bash
sudo systemctl enable --now docker
```

如需更精细控制，可写一个 oneshot 服务拉起 compose：

```ini
# /etc/systemd/system/canarygc.service
[Unit]
Description=CanaryGC Ground Control
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/root/canarygc
ExecStart=/usr/bin/docker compose --profile production up -d app nginx
ExecStop=/usr/bin/docker compose --profile production down

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now canarygc
```

---

## 8. 防火墙与公网访问

`setup-rk3588.sh` 会启用 UFW 并放行常用端口（22、80、3000、5173、8889 等）。要点：

- **务必开启 MAVLink 2 签名**（`MAVLINK_SIGNING_KEY` 或 Integrations 页），否则公网可达的链接任何人都能控制飞控。
- 若开发板在 NAT/蜂窝后，浏览器可能无法直连（STUN 拿到的公网候选不可达）；此时应内网部署或配置 TURN。
- `webrtc`（MediaMTX）使用 host 网络，端口 8554(RTSP)/8888(HLS)/8889(WebRTC)/9997(API)。若无需对外暴露视频 API，可仅放行 8889（WebRTC）与需要者。

---

## 9. 故障排查

| 现象 | 排查 |
| --- | --- |
| 页面打不开 | `docker compose --profile production ps`；`curl http://localhost/version`；`docker logs canarygc_app` |
| 飞控连不上（Dashboard 离线） | 确认串口节点存在；试显式 `MAVLINK_SERIAL_PATH`；`docker exec canarygc_app ls -l /dev/ttyS*`（容器内能看到节点）；查看 `docker logs canarygc_app` 中的 MAVLink autodetect / serial 报错 |
| serialport 报错 | 见第 5 节；可能需在 RK3588 本机重构建镜像，或改用 USB 串口 |
| 摄像头黑屏 | 确认 `.env` 的 `WEBRTC_SOURCE` 正确；`ffmpeg` 命令是否可用；`docker logs canarygc_webrtc`；`v4l2-ctl --list-devices` |
| 保存摄像头源报 `MediaMTX not reachable` | 见第 6 节 MediaMTX API 版本兼容性说明；改用 `.env` 的 `WEBRTC_SOURCE` 方式配置 |
| 串口被 ocuppied | 第 3 节：检查 getty/console 占用，换用另一路 UART 或禁用 console |
| UART 节点不存在 | `/boot/armbianEnv.txt` 启用 overlay 后 reboot，确认 `overlays` 生效 |
