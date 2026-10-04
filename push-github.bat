@echo off
setlocal

REM ============================================================
REM  push-github.bat -- publish GTAWorld to
REM  https://github.com/NemecSoft/GTAWorld
REM
REM  What it does: commit identity -> remotes -> shallow-history fix
REM                -> stage all -> commit -> push branch main
REM
REM  BEFORE YOU RUN IT
REM    Create the EMPTY repo NemecSoft/GTAWorld on https://github.com/new
REM    Do NOT tick "Add a README" / ".gitignore" / "license",
REM    otherwise run:  git pull --rebase origin main   and run this again.
REM
REM  FIRST-RUN AUTHENTICATION (Git Credential Manager pops a window)
REM    Either authorize in the browser, or use
REM      user = NemecSoft
REM      pass = a personal access token from https://github.com/settings/tokens
REM             (classic token with the "repo" scope) -- NOT your account password.
REM
REM  Commit identity is written to THIS repo only (no --global),
REM  so your machine-wide git config stays untouched.
REM
REM  ---- SHALLOW HISTORY, READ THIS ----
REM  This project was cloned with depth=1 from a mirror, so .git\shallow exists
REM  and the history is cut at Kenney's template commit. GitHub REJECTS shallow
REM  pushes ("shallow update not allowed"), so we cannot publish this history as is.
REM  Default (KEEP_TEMPLATE_HISTORY=0): publish ONE fresh root commit authored by
REM  NemecSoft, and keep the template commit reachable under the tag
REM  "kenney-template" (nothing is deleted, and "git checkout -B main
REM  kenney-template" would bring the old line back).
REM  Set KEEP_TEMPLATE_HISTORY=1 to instead fetch the complete upstream history
REM  from the "kenney" remote first and commit on top of it -- needs that mirror
REM  (https://gh-proxy.org/...) to be reachable, and downloads its whole history.
REM
REM  NOTE: keep this file ASCII-only. cmd.exe mis-parses .bat files that contain
REM  multi-byte UTF-8 (comment lines get executed as commands). Chinese docs
REM  live in docs/ and .workbuddy/memory/.
REM ============================================================

set "REPO=https://github.com/NemecSoft/GTAWorld.git"
set "BRANCH=main"
set "GIT_NAME=NemecSoft"
set "GIT_EMAIL=NemecSoft@users.noreply.github.com"
set "MSG=Los Santos Plan v1.6: urban open world, 3-gear driving, missions and economy, procedural sky"
set "KEEP_TEMPLATE_HISTORY=0"

set "ORPHAN=0"

cd /d "D:\AI\GodotProject\GTAWorld"
if errorlevel 1 goto :fail_nocd

echo [1/6] commit identity (this repo only)
git config user.name  "%GIT_NAME%"
git config user.email "%GIT_EMAIL%"
echo       user.name  = %GIT_NAME%
echo       user.email = %GIT_EMAIL%

echo [2/6] remotes
git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto :fail_nogit
git remote get-url origin >nul 2>&1
if errorlevel 1 goto :origin_add
git remote get-url origin | findstr /i "NemecSoft/GTAWorld" >nul
if not errorlevel 1 goto :remote_done
REM  origin still points at the Kenney template repo: keep it under the name
REM  "kenney", and give the name "origin" to the new GitHub repo.
git remote | findstr /x "kenney" >nul
if not errorlevel 1 goto :origin_drop
git remote rename origin kenney
goto :origin_add
:origin_drop
git remote remove origin
:origin_add
git remote add origin "%REPO%"
:remote_done
git remote -v

echo [3/6] shallow history
if not exist ".git\shallow" goto :deep_ok
echo       this clone is shallow (.git\shallow present)
if "%KEEP_TEMPLATE_HISTORY%"=="1" goto :try_unshallow
echo       publishing a fresh root commit instead; template commit -^> tag "kenney-template"
git tag --force kenney-template
if errorlevel 1 goto :fail
set "ORPHAN=1"
goto :staged
:try_unshallow
echo       fetching the full history from remote "kenney" ...
git fetch --unshallow kenney
if errorlevel 1 goto :unshallow_failed
echo       history is complete now, we commit on top of Kenney's commit
goto :staged
:unshallow_failed
echo       unshallow failed (mirror unreachable?) -- falling back to a fresh root commit
git tag --force kenney-template
if errorlevel 1 goto :fail
set "ORPHAN=1"
goto :staged
:deep_ok
echo       history is complete, committing on top of it
:staged

echo [4/6] stage everything (Temp/ ref/ game/ addons/terrain_3d/ are gitignored)
git add -A
if errorlevel 1 goto :fail

echo [5/6] commit
if "%ORPHAN%"=="1" goto :orphan_commit
git diff --cached --quiet
if not errorlevel 1 goto :commit_done
git commit -m "%MSG%"
if errorlevel 1 goto :fail
goto :commit_done
:orphan_commit
git checkout --orphan publish
if errorlevel 1 goto :fail
git add -A
if errorlevel 1 goto :fail
git commit -m "%MSG%"
if errorlevel 1 goto :fail
git branch -f %BRANCH% publish
if errorlevel 1 goto :fail
git checkout %BRANCH%
if errorlevel 1 goto :fail
git branch -d publish
:commit_done
git log --pretty="       %%h %%an  %%s" -1

echo [6/6] push %BRANCH% --^> %REPO%
git push -u origin "%BRANCH%"
if not errorlevel 1 goto :ok

REM Push was rejected. The usual cause is ticking "Add a README / license" when the
REM repo was created: GitHub made its own Initial commit, so the two histories are
REM unrelated. Merge it in while keeping OUR version of every file, then retry once.
REM Deliberately NOT a force push -- that would overwrite the remote history.
echo       rejected -- trying to merge the remote's Initial commit (keeps our files)
git fetch origin "%BRANCH%"
if errorlevel 1 goto :push_help
git merge --allow-unrelated-histories -X ours --no-edit "origin/%BRANCH%"
if errorlevel 1 goto :push_help
git push -u origin "%BRANCH%"
if not errorlevel 1 goto :ok
goto :push_help

:push_help
echo.
echo ---- push failed, check these ----
echo   A repo does not exist yet: create empty NemecSoft/GTAWorld on github.com/new,
echo     then run this file again.
echo   B auth rejected: run  git config --global credential.helper manager
echo     and retry; user = NemecSoft, password = access token (not the account password).
echo   C the remote has commits this script could not merge automatically: open
echo     https://github.com/NemecSoft/GTAWorld and delete that repo, or merge by hand
echo     with  git merge --allow-unrelated-histories -X ours origin/%BRANCH%
echo   D it still says "shallow update not allowed": set KEEP_TEMPLATE_HISTORY=1
echo     above (needs the kenney mirror reachable) or re-clone with full depth.
goto :fail

:ok
echo.
echo Done: https://github.com/NemecSoft/GTAWorld
echo Heads-up: third-party asset and plugin licenses are listed in
echo THIRD_PARTY_LICENSES.md; the Kenney template commit (if orphaned) is kept
echo under the tag "kenney-template" and the remote "kenney".
exit /b 0

:fail_nocd
echo Cannot cd into D:\AI\GodotProject\GTAWorld
goto :fail_end

:fail_nogit
echo Not a git repository (no .git here)
goto :fail_end

:fail
echo.
echo Aborted, nothing was pushed.
:fail_end
endlocal
exit /b 1
