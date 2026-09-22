# mm-utils

OpenWrt package for this project's local modem API and asynchronous SMS
service. It installs:

- `/www/api/handler.lua` for `POST /api/sms`, `GET /api/sms/{id}`, and the
  existing `/api/mac`, `/api/status`, and `/api/cell` routes;
- the `sms_api` Lua validation module;
- the procd-managed `/etc/init.d/sms-api` worker and `/etc/config/sms-api`;
- the file-backed `mmcli` SMS helper;
- an idempotent UCI default that adds the dedicated uhttpd API listener at
  `192.168.2.1:8080` if `uhttpd.api` does not already exist.

The handler's source-IP allowlist remains in `files/www/api/handler.lua` inside
this package. The `device-token` header is ignored by this server.

## Build and install

The root firmware project's build workflow copies `packages/dotin` into the
OpenWrt tree and adds the `dotin` feed. For a local build, copy the package
into that tree first, then refresh the feed and select `mm-utils`:

```sh
cp -a packages/dotin/mm-utils openwrt-25.12/dotin/
cd openwrt-25.12
./scripts/feeds update dotin
./scripts/feeds install -p dotin mm-utils
make menuconfig
```

Select **Network → mm-utils**, or set `CONFIG_PACKAGE_mm-utils=y` in the
firmware configuration. The package selects ModemManager, Lua 5.1, uhttpd's
Lua module, `libubox-lua`, `libubus-lua`, and `luci-lib-jsonc` as dependencies.
No copy of its runtime files should also be placed in the rootfs overlay.

Installing the package enables and starts the SMS worker through OpenWrt's
normal init-script package handling. On first boot, the UCI default adds the
API listener only if it is absent; it does not replace an existing
`uhttpd.api` section. If the device's LAN address differs from
`192.168.2.1`, adjust `uhttpd.api.listen_http` after installation.

The worker's queue and status history are in memory and are lost when the
service restarts. SMS content is written only to private temporary files,
never passed in `mmcli` arguments.

The client contract is documented in the firmware project's
`files/www/api/SMS API Client Integration Guide.md`.

## Host tests

From the root firmware project:

```sh
tests/sms-api/run.sh
```
