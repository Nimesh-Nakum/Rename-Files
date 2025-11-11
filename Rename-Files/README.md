# 🔧 Rename-Files PowerShell Script

A safe and configurable PowerShell utility to batch-rename files by adding a prefix, with full logging, backup, and retry support.

---

## ✨ Features
- ✅ Add prefix to filenames (idempotent)
- 🪶 Supports `-WhatIf` and `-Confirm`
- 🗂 Optional backup before rename
- 🧾 CSV log with timestamps, status, and messages
- 🔁 Retry mechanism for locked files
- 🧱 Graceful error handling and detailed summary

---

## ⚙️ Usage

### 1️⃣ Preview only (safe mode)
```powershell
Rename-Files -SourcePath "E:\Projects\Files" -Filter "*.txt" -Prefix "finance_" -WhatIf
