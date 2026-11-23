# sandbox-audit Specification

## Purpose

Lets a user run an untrusted program in disposable microVMs with one command and get a report of what it did: the network destinations it tried, the files and registry values it changed, and what it wrote.

## Requirements

### Requirement: Audit command
`fc.ps1 audit -Guest windows -Sample <path>` SHALL audit a Windows program. `-Sample` is an executable file or a folder. For a folder, `-Entry` SHALL name the executable inside it as a relative path. `-Arguments` SHALL pass a command line to the program unchanged, including `%` characters.

#### Scenario: Single executable
- **WHEN** the user runs `fc.ps1 audit -Guest windows -Sample C:\q\tool.exe -Arguments '--version'`
- **THEN** `tool.exe` runs with the argument `--version` inside the guest, and a report is written for each run

#### Scenario: Folder without entry
- **WHEN** `-Sample` is a folder and `-Entry` is missing, or names a file that is not in the folder
- **THEN** the command exits 125 with a message naming `-Entry`, and no VM starts

#### Scenario: Percent signs are kept
- **WHEN** `-Arguments` is `-o video.%(ext)s`
- **THEN** the program receives exactly `-o video.%(ext)s`

#### Scenario: Shell characters are not interpreted
- **WHEN** `-Arguments` is `a&b "c|d" (e)`
- **THEN** the program receives exactly `a&b "c|d" (e)`, and no other command runs in the guest

### Requirement: Audit inputs stay out of the repository
The sample SHALL be copied into a new staging folder outside the repository (under `-StagingDir` when given, otherwise the user's temporary folder), and the staging folder SHALL be deleted when the audit ends, whether it succeeds, fails or is interrupted. `-Exclude <name>,...` SHALL leave the named top-level entries of a folder sample out of the copy.

#### Scenario: Exclude user data
- **WHEN** a folder sample contains `app.exe` and `media\`, and the user passes `-Exclude media`
- **THEN** the guest's copy contains `app.exe` and no `media` folder

#### Scenario: Staging removed
- **WHEN** an audit finishes or fails after staging the sample
- **THEN** no staging folder for that audit remains on the host

### Requirement: Isolated and networked runs
Without `-Net`, an audit SHALL do an isolated run and then a networked run, each in a new microVM that is destroyed afterwards. With `-Net isolated` or `-Net networked` it SHALL do only that run. `-Allow` SHALL restrict the networked run's egress exactly as it does for `run`.

#### Scenario: Default pair
- **WHEN** the user audits a program without `-Net`
- **THEN** two run folders are created, the first with network mode `isolated` and the second `networked`, and both run ids are printed

#### Scenario: Allowlist in an audit
- **WHEN** an audit runs with `-Net networked -Allow 203.0.113.0/24`
- **THEN** the proxy refuses every destination outside `203.0.113.0/24`, and the refusals appear in the report

### Requirement: Linux guests are refused
`fc.ps1 audit` without `-Guest windows` SHALL exit 125 before starting a VM, with a message that names `-Guest windows` and the `detonate` and `triage-static` recipes for Linux samples.

#### Scenario: Missing guest
- **WHEN** the user runs `fc.ps1 audit -Sample C:\q\tool.exe`
- **THEN** the command exits 125 and the message names `-Guest windows`, `recipe detonate` and `recipe triage-static`

### Requirement: In-guest snapshots
Before and after the program runs, the guest SHALL record a listing of every file and folder on `C:\` and exports of the `HKLM\SOFTWARE` and `HKCU` registry keys into `C:\work\out\_audit\`. The program SHALL run with `C:\work\out` as its working directory, and `-Timeout` SHALL limit the program alone. The after snapshots SHALL be taken even when the program exceeds `-Timeout`.

#### Scenario: Snapshots collected
- **WHEN** an audit run finishes
- **THEN** the run's `out\_audit\` holds the before and after file listings and the four registry exports

#### Scenario: Program exceeds its time limit
- **WHEN** the program is still running when `-Timeout` expires
- **THEN** the after snapshots are still taken and collected, and the report says the program did not finish within the limit

#### Scenario: Program writes a file
- **WHEN** the audited program writes `result.txt` to its working directory
- **THEN** `result.txt` appears in the run's `out\` folder and is listed in the report

### Requirement: Audit report
Each audit run SHALL write `audit-report.md` and `audit-report.json` in its run folder. They SHALL hold the sample's path and SHA-256, the arguments, the network mode, the program's exit code or that it did not finish, the id of the other run of the pair, and the network, file, registry and output sections below. `meta.json` SHALL record the audit under `audit`.

#### Scenario: Report present
- **WHEN** an audit run completes
- **THEN** `runs\<run-id>\audit-report.md` and `audit-report.json` exist, the JSON holds the same facts as the Markdown, and `meta.json` has an `audit` entry with the sample's file name and SHA-256

#### Scenario: Program did not finish
- **WHEN** the program is still running at the timeout
- **THEN** the report records that the program did not finish, and the run's `exit_code` is 124

### Requirement: Network section
For a networked run, the report SHALL list each distinct host, port and decision from `net.log`, in order of first attempt, with the number of attempts, the resolved addresses, total bytes up and down, and the time of the first attempt. The proxy's own start-up check SHALL be left out. For an isolated run, the report SHALL say that the VM had no network device.

#### Scenario: Grouped destinations
- **WHEN** the program makes two allowed connections to `example.com:443` and one connection to `192.168.1.1:80` that is denied
- **THEN** the report has one `example.com`, `443`, `allowed` row with 2 attempts and summed bytes, and one `192.168.1.1`, `80`, `denied` row

#### Scenario: Isolated run
- **WHEN** the run was isolated
- **THEN** the network section says the VM had no network device, and lists no destinations

### Requirement: File and registry sections
The report SHALL list the paths that appear only in the after listing (created) and only in the before listing (deleted), excluding paths under `C:\work`. It SHALL list registry keys and values added or removed between the before and after exports. Full lists SHALL be saved in the run folder's `audit\` folder. The Markdown report MAY truncate long lists, and it MUST then say so.

#### Scenario: Created file and run key
- **WHEN** the program creates `C:\Users\Public\x.dll` and adds a value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- **THEN** the report lists `C:\Users\Public\x.dll` as created and the new `Run` value as added

#### Scenario: Missing snapshot
- **WHEN** a snapshot file is missing, for example because the run timed out
- **THEN** that section says the snapshot is missing, instead of reporting no changes

### Requirement: Unprivileged report building
The host SHALL parse guest-derived audit data (snapshots, `net.log` fields that the guest supplied, and output file names) only in a process that has no administrator rights, with a time and memory limit. If that process cannot start without administrator rights, or exceeds its limits, the run SHALL keep its results and the report MUST NOT be written.

#### Scenario: Report built without admin rights
- **WHEN** an audit runs from an elevated prompt
- **THEN** the process that reads `out\_audit\` and `net.log` runs with a non-admin token

#### Scenario: Oversized snapshot
- **WHEN** the report builder exceeds its time or memory limit
- **THEN** the run folder keeps its results, no `audit-report.*` is written, and the audit exits 125 naming the run

### Requirement: Audit exit codes
An audit SHALL exit 0 when every run it started finished, whether or not they timed out, and its reports were written, whatever the program's own exit code. It SHALL exit 125 when the sandbox failed to start or collect a run, or a report could not be built. A failed isolated run MUST NOT stop the networked run.

#### Scenario: Program fails
- **WHEN** the audited program exits with code 3
- **THEN** the report records exit code 3, and the audit exits 0

#### Scenario: VM fails to start
- **WHEN** the isolated run's microVM fails to start
- **THEN** the networked run is still attempted, and the audit exits 125

### Requirement: Evidence limits are stated
Every report SHALL state that the program ran as an administrator in the guest and could alter the snapshots, that modified files are not detected, that only host names and ports are visible for encrypted traffic, that programs ignoring the proxy settings get no network and leave no `net.log` entry, and that all quoted text comes from the program and is untrusted.

#### Scenario: Limits section
- **WHEN** any audit report is written
- **THEN** it contains a section that states each of these limits
