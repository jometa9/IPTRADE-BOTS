# IPTRADE Bots

**MetaTrader 4/5 connectors for [IPTRADE](https://github.com/jometa9/IPTRADE-APP) — Expert Advisors + `copybridge.dll`.**

This repo is the source of the MetaTrader side of IPTRADE, the free open-source trade copier:

1. **`copybridge.dll`** (`bridge-dll/`) — a C++17 DLL loaded by the EAs. It runs a local HTTP/WebSocket server inside the terminal, a TCP server for master accounts, and a TCP client for slave accounts.
2. **Expert Advisors** (`bots/mt4/IPTRADE.mq4`, `bots/mt5/IPTRADE.mq5`) — attach to a chart, poll the DLL for incoming copy commands (`create` / `modify` / `cancel` / `reconcile_snapshot`) and push local order events back.

The desktop app that orchestrates everything lives at [jometa9/IPTRADE-APP](https://github.com/jometa9/IPTRADE-APP); the landing page at [jometa9/IPTRADE](https://github.com/jometa9/IPTRADE).

## Structure

| Folder | Description |
|--------|-------------|
| `bridge-dll/` | C++17 source of `copybridge.dll`. Built with CMake + MSVC. |
| `bots/mt4/`, `bots/mt5/` | Expert Advisor source (MQL4/MQL5). Compile in MetaEditor. |
| `include/bridge/` | `BridgeJson.mqh` — minimal JSON parser shared by both EAs. |
| `dist/` | Prebuilt Release DLLs + include, laid out per platform, ready to copy into a terminal. |
| `docs/` | Protocol docs: unified events API, TCP master→slave handshake, snapshot payload, Postman collection. |
| `tools/` | Build and deploy scripts (CMake/MSVC wrappers, deploy to MetaTrader). |
| `tcp-test/` | `ws-listen.js` — tiny Node client to watch the DLL's orders WebSocket while debugging. |

## How it connects to the app

```
MetaTrader terminal                       IPTRADE desktop app
┌────────────────────────────┐            ┌──────────────────────┐
│ IPTRADE EA ⇄ copybridge.dll│──heartbeat─►  Rust API :7777      │
│  HTTP/WS :40000-50000      │◄──config────  (PUT /api/accounts) │
│  TCP master :50000-60000   │            └──────────────────────┘
└────────────┬───────────────┘
             └── one JSON line per event ──► slave terminals (TCP)
```

- Everything binds to `127.0.0.1`. Ports are picked in the 40000–50000 range (HTTP) and +10000 (TCP), persisted next to the DLL.
- Mutating HTTP endpoints require the shared local `x-api-key` / `x-api-secret` headers (`src/ApiAuth.cpp`). These values are committed on purpose: they are a handshake between local processes, not a secret — nothing is reachable from the network.
- The master→slave protocol is newline-delimited JSON over TCP; see `docs/tcp_slave_handshake.md` and `docs/unified_events_api.md`.

## ⚠️ Different architectures

**MT4 and MT5 need different DLL builds:**

- **MT4** is **32-bit** → `copybridge.dll` compiled for **Win32**
- **MT5** is **64-bit** → `copybridge.dll` compiled for **x64**

You cannot use the same DLL on both platforms.

## Build the DLL

From a console with Visual Studio 2022 + CMake in PATH:

```batch
tools\build_all_architectures.bat
```

or individually:

```powershell
pwsh tools/build_copybridge.ps1 -Configuration Release -Architecture Win32   # MT4
pwsh tools/build_copybridge.ps1 -Configuration Release -Architecture x64     # MT5
```

Output lands in `dist/mt4/Libraries/copybridge.dll` and `dist/mt5/Libraries/copybridge.dll`. CI ([build-dll workflow](.github/workflows/build-dll.yml)) builds both architectures on every push.

## Install into MetaTrader

The IPTRADE app installs these files automatically on Windows. To do it by hand:

1. Copy the right DLL to `MQL4/Libraries/` or `MQL5/Libraries/`.
2. Copy `include/bridge/BridgeJson.mqh` to `MQL4/Include/bridge/` and `MQL5/Include/bridge/`.
3. Open `bots/mt4/IPTRADE.mq4` / `bots/mt5/IPTRADE.mq5` in MetaEditor and compile (EAs cannot be compiled in CI — MetaEditor only).
4. Attach the EA to any chart, with **Allow DLL imports** enabled.

`tools/deploy_to_metatrader.ps1` automates the copy for local development.

## Debugging

- `tcp-test/ws-listen.js` connects to the DLL's orders WebSocket: `ACCOUNT_ID=12345678 BRIDGE_PORT=40000 node tcp-test/ws-listen.js`.
- Import `docs/Bridge-API.postman_collection.json` into Postman to poke the local REST API.
- The EA logs to the terminal's Experts tab; the DLL persists its ports in `http_port.txt` / `tcp_port.txt` next to the DLL.

## License

[MIT](LICENSE)
