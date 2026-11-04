@echo off
REM Minimal Windows Nano Server payload: prints sandbox facts and writes out\whoami.txt.
echo Hello from %COMPUTERNAME% (%OS%)
ver
if exist C:\Windows\SysWOW64\cmd.exe (
    C:\Windows\SysWOW64\cmd.exe /c "echo WoW64 32-bit subsystem: OK (%PROCESSOR_ARCHITECTURE%)"
)
REM Nano Server ships no whoami.exe.
echo %USERDOMAIN%\%USERNAME% > out\whoami.txt
echo wrote out\whoami.txt
