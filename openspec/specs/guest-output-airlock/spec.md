# guest-output-airlock Specification

## Purpose

Moves files from a guest to the host without the host ever parsing a guest-produced archive: a disposable airlock VM validates and re-encodes the data, and the host re-checks a minimal format before writing anything.

## Requirements

### Requirement: Airlock for every guest-to-host transfer
Every copy of files from a guest to the host SHALL go through an airlock. The host MUST NOT unpack, list or otherwise parse an archive produced by a guest. There SHALL be no option that collects guest files by extracting the guest's archive on the host.

#### Scenario: Run output collected through the airlock
- **WHEN** a run's command writes `out/report.txt` and finishes
- **THEN** `runs/<run-id>/out/report.txt` exists, and an airlock VM was started and destroyed for the collection

### Requirement: Fresh, isolated airlock per transfer
Each transfer SHALL use a newly started airlock VM of the same guest OS as the source (a Firecracker microVM for Linux guests, a Hyper-V isolated Nano Server VM for Windows guests), in `isolated` network mode, with 1 vCPU, 256 MiB of memory (Linux) and a hard timeout of 5 minutes. The airlock SHALL be destroyed when the transfer ends, whether it succeeded or not, and MUST NOT be reused.

#### Scenario: Two transfers
- **WHEN** two runs collect output one after the other
- **THEN** each collection used a different airlock VM, and neither exists afterwards

#### Scenario: Airlock hangs
- **WHEN** the airlock does not finish within its timeout
- **THEN** the airlock is destroyed, the transfer is refused with a timeout reason, and no guest files are written

### Requirement: Opaque, capped handling on the host
The host SHALL treat the source guest's archive and the airlock's output only as byte streams, copying them without interpretation, except for reading the airlock output's manifest as defined in this spec. Each stream SHALL be capped at the transfer byte limit plus a fixed overhead; a stream exceeding its cap SHALL abort the transfer.

#### Scenario: Endless stream
- **WHEN** a guest streams more data than the cap allows
- **THEN** the host stops reading at the cap, refuses the transfer with a size reason, and writes no guest files

### Requirement: Accepted entry types
Only regular files and directories SHALL be accepted. Symbolic links, hard links, character and block devices, FIFOs, sparse files and any other entry type MUST cause the whole transfer to be refused. File permissions, owners and timestamps from the guest SHALL be discarded.

#### Scenario: Symbolic link in output
- **WHEN** the guest output folder contains a symbolic link
- **THEN** the transfer is refused with a reason naming the link's path, and no guest files are written

#### Scenario: Device node in output
- **WHEN** the guest output folder of a Linux guest contains a FIFO or device node
- **THEN** the transfer is refused with a reason naming the entry

### Requirement: Host-safe file names
Every path SHALL be relative and its components SHALL be valid on NTFS: not empty, not `.` or `..`, no `\ / : * ? " < > |` or control characters, no trailing dot or space, not a reserved device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, with or without an extension). No two paths SHALL differ only in letter case. Paths SHALL be at most 512 characters and 64 levels deep.

#### Scenario: Reserved device name
- **WHEN** the guest output contains a file named `con.txt`
- **THEN** the transfer is refused with a reason naming that path

#### Scenario: Case collision
- **WHEN** the guest output contains both `Report.txt` and `report.txt`
- **THEN** the transfer is refused with a reason naming both paths

#### Scenario: Parent-folder component
- **WHEN** the archive the guest produces contains the entry `../escape.txt`
- **THEN** the transfer is refused and nothing is written outside or inside the destination

### Requirement: Transfer limits
A transfer SHALL be refused when it exceeds any of these limits: 1 GiB of file content in total, 10,000 entries, or 1 GiB for a single file.

#### Scenario: Too many files
- **WHEN** the guest output contains 10,001 files
- **THEN** the transfer is refused with a reason naming the entry limit

### Requirement: Host re-validation of airlock output
The host SHALL apply every rule of this spec again to the airlock's output, independently of the airlock, and SHALL verify each file's SHA-256 hash and that each file's declared byte range lies inside the airlock's output without overlapping another. Any violation SHALL refuse the transfer.

#### Scenario: Tampered airlock output
- **WHEN** the airlock's output declares a file whose hash does not match its bytes
- **THEN** the transfer is refused with a hash-mismatch reason and no guest files are written

#### Scenario: Airlock output with an unsafe name
- **WHEN** the airlock's manifest lists a path containing `..`
- **THEN** the host refuses the transfer even though the airlock produced it

### Requirement: All-or-nothing delivery
Files SHALL be written into a new, empty staging folder and moved into the destination only after every file has been written and verified. A refused or failed transfer SHALL leave the destination without any of the guest's files and SHALL remove the staging folder.

#### Scenario: Refusal after some files were written
- **WHEN** the hash of the 50th of 100 files does not match
- **THEN** the destination contains none of the 100 files and no staging folder remains

### Requirement: Unprivileged validation and unpacking
The validator inside the airlock SHALL run as an unprivileged guest user. The host-side reader SHALL run without administrator or root rights, even when the controller runs elevated or as root, and any process it leaves behind SHALL be terminated before its output is moved into place.

#### Scenario: Elevated Windows controller
- **WHEN** an elevated `fcctl-win.ps1` collects a Windows run's output
- **THEN** the host-side reader process runs with a non-administrator token

### Requirement: No image changes
The airlock SHALL work with the existing base images; the host SHALL supply the validator to each airlock at transfer time.

#### Scenario: Stock image
- **WHEN** the configured Linux rootfs or Nano Server image is the one setup installed
- **THEN** airlock transfers work without rebuilding or changing that image

### Requirement: Empty output skips the airlock
When the guest output folder is missing or empty, the system SHALL NOT start an airlock and SHALL leave the destination folder empty.

#### Scenario: Run without output
- **WHEN** a run's command writes nothing to the output folder
- **THEN** no airlock VM is started and `runs/<run-id>/out/` is empty

### Requirement: Refusal reporting
A refused or failed transfer SHALL print an error naming the reason and, where applicable, the offending path, and SHALL record the outcome (`ok`, `refused` or `failed`, with reason, file count and byte count) in the run's `meta.json` under `collection`.

#### Scenario: Refusal recorded
- **WHEN** a run's output is refused because it contains a symbolic link
- **THEN** `meta.json` has `collection.status` equal to `refused` and a reason naming the link
