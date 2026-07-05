@echo off
REM Registers the "poever" merge driver for this repo (Windows cmd/PowerShell).
REM Version-line conflicts in InGameStateMonitor.ahk / README.md / CLAUDE.md then
REM auto-resolve to the higher version on LOCAL merges (see .gitattributes +
REM tools\git-merge-version.py). Run once per clone:  tools\setup-git-merge-driver.bat
REM GitHub's web "Merge" button does NOT use local merge drivers — merge locally to benefit.
git config merge.poever.name "Keep the higher PoEformance version on conflict"
git config merge.poever.driver "python tools/git-merge-version.py %%O %%A %%B %%L"
echo Configured the "poever" merge driver. Version-line conflicts now auto-resolve on local merges.
