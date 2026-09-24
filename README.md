# luci-app-szu-drcom

面向 **深圳大学（Shenzhen University, SZU）** 宿舍区校园网的 OpenWrt / ImmortalWrt Dr.COM 认证插件，带 LuCI 图形化控制面板。本项目高度依赖 WorkBuddy 与 DeepSeek Harness 完成，如有 bug 请提交 issue。

## 插件功能

- 路由器开机自动认证，电脑/手机连上 Wi-Fi 即可上网，无需每台设备单独弹 Portal 认证页面
- 后台守护进程定时心跳检查，掉线自动重连
- LuCI 页面一键登录 / 下线，实时查看在线状态、账号 IP、运行日志

## 参考仓库

| 仓库 | 协议 | 本项目借鉴了什么 |
| --- | --- | --- |
| [BH4ME/szu_drcom](https://github.com/BH4ME/szu_drcom) | Dr.COM **ePortal**（HTTP） | SZU 的 Portal 地址、登录参数、在线状态判定逻辑 |
| [sweetcornna/jlu_drcom](https://github.com/sweetcornna/jlu_drcom) | dogcom **UDP** 认证 | LuCI 插件工程结构、procd 服务脚本、状态/日志面板交互设计 |

## 目录结构

```
Makefile                                     OpenWrt 包定义
files/etc/config/drcom_szu                   UCI 默认配置
files/etc/init.d/drcom_szu                   procd 服务脚本
files/usr/bin/szu-drcom                      ePortal 客户端（ash 实现）
files/usr/lib/lua/luci/controller/szu_drcom.lua   LuCI 控制器（菜单 + JSON 接口）
files/usr/lib/lua/luci/view/szu_drcom/status.htm  LuCI 状态面板页面
files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json  权限声明
scripts/build-ipk.sh                         本地打包 ipk
scripts/build-apk.sh                         本地打包 apk
```

## 构建

这个包不分处理器架构，直接打包即可。这里需要 Linux 环境，实体机、虚拟机、子系统理论上均可。请把下文 scp 命令中的 router 字段换成你路由器的实际 IP.

### 方式一：本地直接打包 ipk（无需 SDK）
首先，拉取本项目的源码，在根目录执行：
```sh
sh scripts/build-ipk.sh          # 产物在 dist/ 目录
# dist/luci-app-szu-drcom_1.0.0-4_all.ipk
```

只需要 `tar` 和 `gzip`。版本号自动从 `Makefile` 的 `PKG_VERSION` / `PKG_RELEASE` 读取，
**下文示例中的文件名以你自己 `Makefile` 里的版本号为准**。

传到路由器安装：


```sh
scp dist/luci-app-szu-drcom_1.0.0-4_all.ipk root@router:/tmp/
ssh root@router 'opkg install /tmp/luci-app-szu-drcom_1.0.0-4_all.ipk'
```
你也可以直接在 LuCI Web 端直接上传并安装。

### 方式二：本地直接打包 apk（固件用 apk 包管理器时）

#### 注意：这种情况并未被测试，笔者仅测试过方式一

适用于 OpenWrt 25.12 或更高版本： 
拉取本项目的源码，在根目录执行：
```sh
sh scripts/build-apk.sh          # 产物在 dist/ 目录
# dist/luci-app-szu-drcom-1.0.0-r4.apk
```

传到路由器安装（`apk` 对本地未签名的包必须加 `--allow-untrusted`）：

```sh
scp dist/luci-app-szu-drcom-1.0.0-r4.apk root@router:/tmp/
ssh root@router 'apk add --allow-untrusted /tmp/luci-app-szu-drcom-1.0.0-r4.apk'
```

脚本输出的默认是 **apk v2** 容器，实测可同时被 apk-tools 2.14.6 和 3.0.8 安装，
覆盖 OpenWrt 24.x（apk 实验版）到 25.12+ 以及 Alpine。

还有个 `--v3` 选项，产出 apk-tools 3.x 原生的 ADB 容器，但需要构建机上装有
apk-tools 3.x 的 `apk mkpkg`：

```sh
sh scripts/build-apk.sh --v3
```
### 方式三：手动拷贝安装（不打包）

```sh
scp files/usr/bin/szu-drcom              root@router:/usr/bin/szu-drcom
scp files/etc/init.d/drcom_szu           root@router:/etc/init.d/drcom_szu
scp files/etc/config/drcom_szu           root@router:/etc/config/drcom_szu
ssh root@router '
  mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/szu_drcom /usr/share/rpcd/acl.d
  chmod +x /usr/bin/szu-drcom /etc/init.d/drcom_szu
  chmod 600 /etc/config/drcom_szu
  rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
  /etc/init.d/rpcd reload
  /etc/init.d/uhttpd restart
'
scp files/usr/lib/lua/luci/controller/szu_drcom.lua    root@router:/usr/lib/lua/luci/controller/szu_drcom.lua
scp files/usr/lib/lua/luci/view/szu_drcom/status.htm   root@router:/usr/lib/lua/luci/view/szu_drcom/status.htm
scp files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json root@router:/usr/share/rpcd/acl.d/luci-app-szu-drcom.json
```

依赖：`curl`（或 `uclient-fetch` / `wget`）、`uci`、`luci-base`、`luci-lua-runtime`。

## 使用

进入 **LuCI → 服务 → SZU DrCOM**：

1. 填**校园卡号**（校园网账号）和统一身份认证密码
2. 先点 **探测参数**，确认 `wlan_user_ip` / `wlan_ac_ip` 是否正确（默认已预置深大常用值）
3. 勾选 **启用守护进程**、**离线时自动登录**
4. 点 **保存并应用**
5. 点 **立即登录**

其余选项保持默认即可。「高级参数」折叠区里的 `login_method`、`wlan_ac_name`、
`ifname` 一般不用改，含义见下方配置项。

页面每 5 秒刷新一次在线状态与日志。

### 命令行

```sh
szu-drcom status    # 查询在线状态，打印 online / offline / error（error 时退出码为 2）
szu-drcom login     # 登录
szu-drcom logout    # 下线
szu-drcom probe     # 探测 Portal 参数
szu-drcom daemon    # 前台运行守护进程（服务脚本内部使用）

/etc/init.d/drcom_szu start|stop|restart|enable|disable
logread -e szu-drcom          # 查看 syslog
tail -f /tmp/szu-drcom.log    # 查看详细日志
```

## 配置项

配置文件 `/etc/config/drcom_szu`：

LuCI 页面上只显示常用项，`wlan_ac_name`、`login_method`、`ifname` 收在
「高级参数」折叠区里，一般不用动。

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `0` | 启用守护进程 |
| `username` / `password` | 空 | 校园卡号与统一身份认证密码 |
| `portal_host` | `172.30.255.42` | Portal 服务器地址 |
| `portal_port` | `801` | ePortal 端口 |
| `ac_ip` | `172.30.255.41` | AC（接入控制器）地址，即 `wlan_ac_ip` |
| `wlan_user_ip` | 空（自动） | 本机校园网 IP，探测不到时手动填 |
| `wlan_user_mac` | 空（自动） | 12 位无分隔符大写 MAC，账号绑 MAC 时填 |
| `interval` | `60` | 心跳检查间隔（秒），10–3600 |
| `timeout` | `8` | 单次 HTTP 请求超时（秒），3–30 |
| `startup_delay` | `5` | 开机后等待 WAN 就绪的秒数 |
| `auto_login` | `1` | 离线时自动登录 |

### 高级参数

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `login_method` | `1` | 登录方式，见下方详解 |
| `ac_name` | 空 | AC 名称，即 `wlan_ac_name`，深大绝大多数区域留空 |
| `ifname` | 空（自动） | 读取 MAC 用的出口网卡，如 `eth0.2`、`wan` |
| `status_path` | `/drcom/chkstatus` | 状态查询路径 |
| `login_path` | `/eportal/portal/login` | 登录路径 |
| `logout_path` | `/eportal/portal/logout` | 下线路径 |

### `login_method` 是什么

这是 Dr.COM ePortal 登录请求里一个**必须带、但我们没法从协议里推导出含义**
的固定参数。它出现在登录 URL 里：

```
http://172.30.255.42:801/eportal/portal/login
  ?callback=drlogin
  &login_method=1          ← 就是它
  &user_account=...
  &user_password=...
  &wlan_user_ip=...
```

已知的实际情况：

- **`1` = 账号密码直接认证**，这是绝大多数高校 Portal（含深大）使用的值。
  各类公开抓包样本里，`loginMethod=1` 也总是和标准 ePortal 登录
  （`c=ACSetting&a=Login`）成对出现。
- 少数学校会用到 `2` 或其他值，通常是**运营商选择 / 二次跳转**之类由该校
  自行定制的认证分支，含义并没有统一规范。

**深大固定为 `1`，不需要改。** 插件默认值就是 `1`。

什么时候才需要动它：登录一直失败、而你确认账号密码和 Portal 地址都没问题时，
按「如何自己抓包确认参数」那一节抓一次浏览器里的真实登录请求，看它 URL 里的
`login_method` 是几，填成同样的值即可。除此之外没有理由修改。

## 如何自己抓包确认参数

如果默认值在你的区域不通（不同宿舍区 AC 可能不同），用浏览器抓一次登录请求：

1. 电脑连校园网，打开浏览器访问任意外网地址，会跳转到 Portal 登录页
2. 打开开发者工具 → 网络面板，勾选保留日志
3. 输入账号密码登录
4. 找到 `eportal/portal/login` 这条请求，复制它完整的查询参数
5. 把 `wlan_ac_ip`、`wlan_ac_name`、`wlan_user_ip`、`wlan_user_mac` 填到插件里

也可以在路由器上先跑 `szu-drcom probe`，它会从 `chkstatus` 响应里读出服务器认可的本机 IP 和 AC 标识。

## 故障排查

| 现象 | 排查方向 |
| --- | --- |
| **安装后菜单里完全看不到「SZU DrCOM」** | 见下方「菜单不显示」专节 |
| 页面一直显示「连接异常」 | 确认 WAN 已拿到校园网 IP；`ping 172.30.255.42`；确认 Portal 地址/端口正确 |
| 提示「无法获取本机 IP」 | 在 `wlan_user_ip` 里手动填写校园网 IP |
| 登录提示账号或密码错误 | 确认用的是**统一身份认证**密码，不是校园卡查询密码 |
| 登录成功但仍无法上网 | 检查路由器 DNS 与默认路由，或账号是否被 MAC 绑定（`wlan_user_mac`） |
| 频繁掉线 | 适当调大 `interval`；查看日志里的失败原因 |
| 页面 404 / 菜单不显示 | 清缓存：`rm -rf /tmp/luci-indexcache /tmp/luci-modulecache`，重启 uhttpd |

### 菜单不显示（最常见）

LuCI 从 23.05/24.10 起改用 ucode 构建菜单（`dispatcher.uc`）。它会同时扫描
`/usr/share/luci/menu.d/*.json` 和 `/usr/lib/lua/luci/controller/*.lua`，但后者
**只有在装了 `luci-lua-runtime` 时才会被处理**，否则只打一条 warn，界面上静默消失。

按顺序排查：

```sh
# 1. Lua 运行时在不在（最关键）
opkg list-installed | grep luci-lua-runtime
# 没有就装：
opkg update && opkg install luci-lua-runtime

# 2. 控制器文件到位没有
ls -l /usr/lib/lua/luci/controller/szu_drcom.lua \
      /usr/lib/lua/luci/view/szu_drcom/status.htm

# 3. 清缓存并重启（索引缓存按文件列表 hash，装完新包必须重建）
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/uhttpd restart
/etc/init.d/rpcd restart

# 4. 抓真实报错
logread | tail -40
```

第 4 步如果看到：

```
Lua controller /usr/lib/lua/luci/controller/szu_drcom.lua present but no Lua runtime installed.
```

就确认是缺 `luci-lua-runtime`，装上即可，不用重新装本插件。

如果是 `Failed to load controller` 或 Lua traceback，说明控制器本身报错（例如
Lua 版本不兼容），把完整报错贴出来。

浏览器端记得 `Ctrl+F5` 强刷一次。

> OpenWrt 25.12 之后 LuCI 主线已全面转向 ucode/JSON，部分固件可能不再提供
> `luci-lua-runtime`。这种情况下本插件（Lua 控制器版）无法工作，需要迁移到
> `menu.d` JSON + JS 视图的现代写法。

## 安全提示

- `/etc/config/drcom_szu` 含明文密码，权限已设为 `600`，请勿上传到公开仓库
- 日志只记录结果信息，不打印密码；状态文件 `/tmp/szu-drcom.state` 权限同为 `600`
- 状态轮询接口**不会下发明文密码**：页面上的密码框留空即表示「保持原密码不变」

## 许可

MIT
