# Sandbox audit: `yt-dlp.exe` (networked)

- Sample: `C:\Tools\yt-dlp`
- Program: `yt-dlp.exe`, SHA-256 `08e30ae43a9f0c2d3ed716ef05a95fc7b4ee9d93862148e344bad3de51b93f3c`
- Arguments: `-v -o video.%(ext)s https://example.com/watch?v=x`
- Run: `20261123-200325-dc3b` (other run of this audit: `20261123-200123-acfd`)
- Program result: exited with code 1

## Network

| host | port | decision | attempts | addresses | reason | bytes up | bytes down | first attempt |
|---|---|---|---|---|---|---|---|---|
| `www.youtube.com` | 443 | `allowed` | 2 | `142.251.150.4, 142.251.150.5` | `public` | 4524 | 108112 | `2026-11-23T20:03:33.815Z` |
| `192.168.1.1` | 80 | `denied` | 1 | `192.168.1.1` | `private` | 0 | 0 | `2026-11-23T20:03:34.100Z` |

## Files created and deleted (outside C:\work)

Created: 2, deleted: 1. Modified files are not detected.

Created:

```text
C:\Users\Public\x.dll
C:\Users\Public\we`ird|name.txt
```

Deleted:

```text
C:\Users\Public\old.log
```

## Registry changes

### HKLM\SOFTWARE

Added: 0, removed: 0, changed: 1.

Changed:

```text
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Notifications\Data] "418A073AA3BC1C75": hex:50,00,00,00,01,02 -> hex:51,00,00,00,01,02
```

Changes under `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Notifications\Data` are normally made by Windows itself while any program runs.

### HKCU

Added: 3, removed: 0, changed: 0.

Added:

```text
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run] "Updater"="C:\\Users\\Public\\x.dll"
[HKEY_CURRENT_USER\Software\FcAuditProbe]
[HKEY_CURRENT_USER\Software\FcAuditProbe] "x"="1"
```

## Files the program wrote to its working directory

- `out\page.html` (15 bytes)

The program's console output is in `stdout.log` and `stderr.log` in the run folder.

## Limits of this evidence

- The program ran as an administrator (ContainerAdministrator) inside the guest, so it could have altered the snapshots this report is built from. This is evidence, not a verdict.
- Modified files are not detected: only files and folders that were created or deleted.
- For encrypted traffic only host names and ports are visible, not URLs or content.
- Programs that ignore the HTTP_PROXY/HTTPS_PROXY settings get no network at all and leave no net.log entry.
- All quoted text (paths, registry data, host names, program output) comes from the program and is untrusted.
