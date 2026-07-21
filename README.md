
# 🔌 CommandBridge — Remote Script Executor GUI

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)
![GUI](https://img.shields.io/badge/GUI-WPF-purple.svg)
![Version](https://img.shields.io/badge/version-2.0-green.svg)

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-☕-FFDD00?style=for-the-badge)](https://www.buymeacoffee.com/mabdulkadrx)

---

## 📖 Overview

**CommandBridge** is a modern, high-performance graphical interface for executing PowerShell commands across **multiple remote Windows devices** concurrently. Built with WPF, it includes pre-execution validation (Ping + WinRM), alternate credential support, real-time status tracking, and detailed logging.

---

## 🖥 Screenshot

![Screenshot](Screenshot.png)

---

## ✨ Core Features

### 🔹 Core Execution
- Run any PowerShell script/command on **multiple remote targets** simultaneously
- Configurable concurrency (1–32 threads)
- **Pre-execution checks**: Ping test (optional), WinRM (WSMan) connectivity test (optional)
- Support for **alternate credentials** (domain or local accounts)
- Cancellable at any time (graceful stop of pending and running jobs)

### 🔹 Smart UI / UX
- Rich **WPF interface** with real-time **Message Center** logs
- Live **device status grid** (Queued → Running → Success/Failed/Cancelled)
- Progress bar with completed task count
- **Device list management**:
  - Add single targets manually
  - Paste multiple targets (separated by commas, newlines, or semicolons)
  - Import targets from CSV (auto-detects columns: Computer/Device/Name/Hostname/Target)
  - Clear entire list
- **Export results** to CSV and **save command output** per device to text files

### 🔹 Logging & Output
- Logs every step to a timestamped file: `C:\ProgramData\CommandBridge\Logs\CommandBridge_YYYYMMDD_HHmmss.log`
- Command output can be saved individually for each target (optional)
- **Message Center** with colour-coded levels (INFO, SUCCESS, WARN, ERROR, etc.)
- Copy full console output to clipboard
- Clear message log with one click

### 🔹 Safety & Reliability
- 2-minute timeout per remote execution (prevents hanging)
- Automatically restarts script in **STA mode** (required for WPF)
- Prevents multiple concurrent runs
- Cancellation stops new tasks and interrupts running pipelines

---

## ⚙️ Requirements

### System
- Windows 10 / 11
- Windows PowerShell 5.1
- Network access to target devices

### Permissions
- The executing user (or the alternate credentials) must have **WinRM (PowerShell Remoting)** permissions on the target machines
- `Enable-PSRemoting -Force` may be needed on some targets

---

## 🚀 How to Run

### Option 1 — PowerShell Script

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\CommandBridge.ps1
```

The script will auto-restart in STA mode if needed.

### Option 2 — Packaged EXE (Self-Signed with PSWrap)

The `.exe` was compiled and self-signed using [PSWrap](https://github.com/mabdulkadr/PSWrap) — a PowerShell Script to EXE Compiler with built-in code signing support.

```
CommandBridge.exe
```

No PowerShell console required.

---

## 🔄 Typical Workflow

1. **Add target computers** — using the input box, paste from clipboard, or import a CSV
2. **Check/uncheck** the devices you want to target (all checked by default)
3. **Write your PowerShell command** in the "Execution Command" box (e.g., `Get-Service`, `Get-Process`, custom logic)
4. **Configure options**:
   - Ping check (recommended)
   - WSMan check (recommended)
   - Alternate credentials (optional — click the checkbox to open a credential dialog)
   - Save output to file (per device)
   - Max concurrent threads (default 8)
5. Click **Run Execution**
6. Monitor real-time logs and the device status grid
7. After completion, use **Export CSV** to save the status table or **Copy Output** to copy all logs

---

## 📦 Example Command

```powershell
Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First 5
```

This will return the top 5 processes by CPU usage from each remote machine.

---

## 🧠 Smart Auto-Detection & Behaviour

- If a target is unreachable via Ping or WSMan (according to your settings), the task is immediately marked as **Failed** without attempting command execution
- All commands run asynchronously — the UI remains fully responsive
- The status grid automatically refreshes when a device transitions (Queued → Running → Success/Failed)

---

## 📁 Folder Structure

Automatically created on first run:

```
C:\ProgramData\CommandBridge\
├── Logs\
│   ├── CommandBridge_20260518_143022.log
│   └── Outputs\          (saved command outputs if enabled)
└── Temp\                 (internal temporary files)
```

---

## 🐛 Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Script doesn't launch | PowerShell not in STA mode | Script auto-restarts in STA; if it fails, run `powershell -STA` manually |
| Cannot connect to target | WinRM not enabled on target | Run `Enable-PSRemoting -Force` on target |
| "Access denied" on remote | Insufficient WinRM/admin permissions | Use alternate credentials or check domain permissions |
| Ping check fails | Target unreachable or ICMP blocked | Verify network connectivity; disable Ping check if ICMP is blocked |
| Jobs timeout | Target too slow or hung | Increase timeout in script or check target health |

---

## 📜 License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).

---

## 👤 Author

**Mohammad Abdulkader Omar**
Website: https://momar.tech
LinkedIn: https://www.linkedin.com/in/mabdulkadr/
Version: **2.0**

---

## ☕ Support

If this project helps you, consider supporting it:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-☕-FFDD00?style=for-the-badge)](https://www.buymeacoffee.com/mabdulkadrx)

---

## ⚠ Disclaimer

These scripts are provided as-is. Test them in a staging environment before applying them to production. The author is not responsible for any unintended outcomes resulting from their use. Ensure you have proper authorisation before executing commands on remote systems.
