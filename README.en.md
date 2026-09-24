# luci-app-szu-drcom

An OpenWrt / ImmortalWrt Dr.COM authentication plugin for the dormitory-area campus network of **Shenzhen University (SZU)**, with a graphical LuCI control panel. This project was completed largely with the help of WorkBuddy and DeepSeek Harness; if you find a bug, please submit an issue.

## Plugin features

- The router authenticates automatically at boot; once a computer or phone joins the Wi-Fi it can go online, with no need for each device to pop up the Portal authentication page individually
- The background daemon performs periodic heartbeat checks and reconnects automatically after a disconnect
- One-click login / logout on the LuCI page; view online status, the account IP, and running logs in real time

## Reference repositories

| Repository | Protocol | What this project drew from it |
| --- | --- | --- |
| [BH4ME/szu_drcom](https://github.com/BH4ME/szu_drcom) | Dr.COM **ePortal** (HTTP) | SZU's Portal address, login parameters, online-status determination logic |
| [sweetcornna/jlu_drcom](https://github.com/sweetcornna/jlu_drcom) | dogcom **UDP** authentication | LuCI plugin project structure, procd service script, status/log panel interaction design |

## Directory structure

```
Makefile                                     OpenWrt package definition
files/etc/config/drcom_szu                   UCI default configuration
files/etc/init.d/drcom_szu                   procd service script
files/usr/bin/szu-drcom                      ePortal client (implemented in ash)
files/usr/lib/lua/luci/controller/szu_drcom.lua   LuCI controller (menu + JSON API)
files/usr/lib/lua/luci/view/szu_drcom/status.htm  LuCI status panel page
files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json  permission declarations
scripts/build-ipk.sh                         build ipk locally
scripts/build-apk.sh                         build apk locally
```

## Build

This package does not depend on the processor architecture, so you can package it directly. A Linux environment is required here — in theory a physical machine, virtual machine, or subsystem will all work. Please replace the router field in the scp commands below with your router's actual IP.

### Method 1: Package the ipk locally (no SDK required)
First, pull the source code of this project and run the following in the root directory:
```sh
sh scripts/build-ipk.sh          # output goes into the dist/ directory
# dist/luci-app-szu-drcom_1.0.0-4_all.ipk
```

Only `tar` and `gzip` are required. The version number is read automatically from `PKG_VERSION` / `PKG_RELEASE` in the `Makefile`;
**the filenames in the examples below follow the version number in your own `Makefile`**.

Transfer it to the router and install:


```sh
scp dist/luci-app-szu-drcom_1.0.0-4_all.ipk root@router:/tmp/
ssh root@router 'opkg install /tmp/luci-app-szu-drcom_1.0.0-4_all.ipk'
```
You can also upload and install it directly from the LuCI web interface.

### Method 2: Package the apk locally (when the firmware uses the apk package manager)

#### Note: this case has not been tested; the author has only tested Method 1

Applies to OpenWrt 25.12 or later: 
Pull the source code of this project and run the following in the root directory:
```sh
sh scripts/build-apk.sh          # output goes into the dist/ directory
# dist/luci-app-szu-drcom-1.0.0-r4.apk
```

Transfer it to the router and install (`apk` requires `--allow-untrusted` for locally unsigned packages):

```sh
scp dist/luci-app-szu-drcom-1.0.0-r4.apk root@router:/tmp/
ssh root@router 'apk add --allow-untrusted /tmp/luci-app-szu-drcom-1.0.0-r4.apk'
```

By default the script outputs an **apk v2** container; in testing it can be installed by both apk-tools 2.14.6 and 3.0.8,
covering OpenWrt 24.x (experimental apk) through 25.12+ as well as Alpine.

There is also a `--v3` option, which produces the ADB container native to apk-tools 3.x, but it requires
`apk mkpkg` from apk-tools 3.x to be installed on the build machine:

```sh
sh scripts/build-apk.sh --v3
```
### Method 3: Manual copy installation (no packaging)

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

Dependencies: `curl` (or `uclient-fetch` / `wget`), `uci`, `luci-base`, `luci-lua-runtime`.

## Usage

Go to **LuCI → Services → SZU DrCOM**:

1. Fill in your **campus card number** (campus network account) and the unified identity authentication password
2. First click **Probe parameters** to confirm whether `wlan_user_ip` / `wlan_ac_ip` are correct (commonly used SZU values are preconfigured by default)
3. Check **Enable daemon** and **Auto-login when offline**
4. Click **Save & Apply**
5. Click **Log in now**

Leave the other options at their defaults. The `login_method`, `wlan_ac_name`, and
`ifname` options in the collapsed "Advanced parameters" section generally do not need to be changed; see the configuration options below for their meanings.

The page refreshes the online status and logs every 5 seconds.

### Command line

```sh
szu-drcom status    # query online status, print online / offline / error (exit code 2 on error)
szu-drcom login     # log in
szu-drcom logout    # log out
szu-drcom probe     # probe Portal parameters
szu-drcom daemon    # run the daemon in the foreground (used internally by the service script)

/etc/init.d/drcom_szu start|stop|restart|enable|disable
logread -e szu-drcom          # view the syslog
tail -f /tmp/szu-drcom.log    # view the detailed log
```

## Configuration options

Configuration file `/etc/config/drcom_szu`:

The LuCI page shows only the common options; `wlan_ac_name`, `login_method`, and `ifname` are kept
in the collapsed "Advanced parameters" section and generally don't need to be touched.

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `0` | Enable the daemon |
| `username` / `password` | empty | Campus card number and unified identity authentication password |
| `portal_host` | `172.30.255.42` | Portal server address |
| `portal_port` | `801` | ePortal port |
| `ac_ip` | `172.30.255.41` | AC (Access Controller) address, i.e. `wlan_ac_ip` |
| `wlan_user_ip` | empty (auto) | This machine's campus network IP; fill in manually when it cannot be probed |
| `wlan_user_mac` | empty (auto) | 12-digit uppercase MAC without separators; fill in when the account is MAC-bound |
| `interval` | `60` | Heartbeat check interval (seconds), 10–3600 |
| `timeout` | `8` | Timeout for a single HTTP request (seconds), 3–30 |
| `startup_delay` | `5` | Seconds to wait after boot for the WAN to become ready |
| `auto_login` | `1` | Auto-login when offline |

### Advanced parameters

| Option | Default | Description |
| --- | --- | --- |
| `login_method` | `1` | Login method; see the detailed explanation below |
| `ac_name` | empty | AC name, i.e. `wlan_ac_name`; leave empty in the vast majority of SZU areas |
| `ifname` | empty (auto) | Egress interface used to read the MAC, e.g. `eth0.2`, `wan` |
| `status_path` | `/drcom/chkstatus` | Status query path |
| `login_path` | `/eportal/portal/login` | Login path |
| `logout_path` | `/eportal/portal/logout` | Logout path |

### What is `login_method`

This is a fixed parameter in the Dr.COM ePortal login request that **must be included, but whose meaning cannot be derived from the protocol**.
It appears in the login URL:

```
http://172.30.255.42:801/eportal/portal/login
  ?callback=drlogin
  &login_method=1          ← that's the one
  &user_account=...
  &user_password=...
  &wlan_user_ip=...
```

Here is what is actually known:

- **`1` = direct username/password authentication** — this is the value used by the vast majority of university portals (SZU included).
  In all kinds of publicly available packet-capture samples, `loginMethod=1` always appears together with the standard ePortal login
  (`c=ACSetting&a=Login`).
- A small number of schools use `2` or other values, usually **carrier selection / secondary redirect** or similar
  authentication branches customized by that school itself, with no unified specification for their meaning.

**SZU is fixed at `1`; you don't need to change it.** The plugin's default value is `1`.

When would you actually need to change it: if login keeps failing and you are sure the username, password, and Portal address are all fine,
capture the real login request in your browser once following the "How to capture packets yourself to confirm parameters" section, look at
`login_method` in its URL, and fill in the same value. Other than that, there is no reason to change it.

## How to capture packets yourself to confirm parameters

If the default values don't work in your area (the AC may differ between dormitory areas), capture a login request with your browser once:

1. Connect the computer to the campus network, open a browser and visit any external website; you will be redirected to the Portal login page
2. Open Developer Tools → Network panel and enable Preserve log
3. Enter your username and password to log in
4. Find the `eportal/portal/login` request and copy its complete query parameters
5. Fill `wlan_ac_ip`, `wlan_ac_name`, `wlan_user_ip`, and `wlan_user_mac` into the plugin

You can also run `szu-drcom probe` on the router first; it reads the server-accepted local IP and AC identifier from the `chkstatus` response.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| **"SZU DrCOM" is completely missing from the menu after installation** | See the dedicated "Menu not showing" section below |
| The page keeps showing "Connection abnormal" | Confirm the WAN has obtained a campus network IP; `ping 172.30.255.42`; confirm the Portal address/port are correct |
| Message: "Unable to obtain the local IP" | Manually fill in the campus network IP in `wlan_user_ip` |
| Login reports an incorrect username or password | Confirm you are using the **unified identity authentication** password, not the campus card inquiry password |
| Login succeeds but you still cannot go online | Check the router's DNS and default route, or whether the account is MAC-bound (`wlan_user_mac`) |
| Frequent disconnects | Increase `interval` appropriately; check the logs for the failure reason |
| Page 404 / menu not showing | Clear the cache: `rm -rf /tmp/luci-indexcache /tmp/luci-modulecache`, restart uhttpd |

### Menu not showing (most common)

Starting with 23.05/24.10, LuCI builds its menu with ucode (`dispatcher.uc`). It scans both
`/usr/share/luci/menu.d/*.json` and `/usr/lib/lua/luci/controller/*.lua`, but the latter are
**only processed when `luci-lua-runtime` is installed**; otherwise only a warning is logged and they silently disappear from the interface.

Troubleshoot in this order:

```sh
# 1. Is the Lua runtime present (most critical)
opkg list-installed | grep luci-lua-runtime
# If it isn't, install it:
opkg update && opkg install luci-lua-runtime

# 2. Are the controller files in place
ls -l /usr/lib/lua/luci/controller/szu_drcom.lua \
      /usr/lib/lua/luci/view/szu_drcom/status.htm

# 3. Clear the cache and restart (the index cache is a hash of the file list and must be rebuilt after installing a new package)
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/uhttpd restart
/etc/init.d/rpcd restart

# 4. Capture the real error
logread | tail -40
```

If in step 4 you see:

```
Lua controller /usr/lib/lua/luci/controller/szu_drcom.lua present but no Lua runtime installed.
```

then it is confirmed that `luci-lua-runtime` is missing; just install it — no need to reinstall this plugin.

If you get `Failed to load controller` or a Lua traceback, the controller itself is erroring (for example due to
Lua version incompatibility); paste the full error output.

Remember to hard-refresh the browser once with `Ctrl+F5`.

> After OpenWrt 25.12, upstream LuCI has fully moved to ucode/JSON, and some firmwares may no longer provide
> `luci-lua-runtime`. In that case this plugin (the Lua controller version) cannot work; it needs to be migrated to
> the modern `menu.d` JSON + JS view approach.

## Security notes

- `/etc/config/drcom_szu` contains a plaintext password; its permissions are set to `600` — do not upload it to a public repository
- The logs record only result information and never print the password; the state file `/tmp/szu-drcom.state` also has `600` permissions
- The status polling interface **does not push down the plaintext password**: leaving the password box on the page empty means "keep the existing password unchanged"

## License

MIT
