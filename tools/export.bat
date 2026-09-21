@echo off
rem ===================================================================
rem  Drag one or more PDF files onto this file to export the strokes
rem  made with pencil-handwriting.koplugin.
rem
rem  - finds <book>.sdr\pencil_handwriting.lua next to each PDF
rem  - installs PyMuPDF automatically the first time (no manual pip)
rem  - writes the result to a "pencil-export" folder next to each PDF
rem
rem  The original PDF is never modified.
rem  This file is intentionally plain ASCII: non-ASCII batch content is
rem  unreliable across console code pages.
rem ===================================================================
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "SCRIPT=%HERE%export_annotations.py"

if not exist "%SCRIPT%" (
  echo.
  echo   export_annotations.py is not next to this .bat file.
  echo   Keep both files in the same folder.
  echo.
  pause
  exit /b 1
)

if "%~1"=="" (
  echo.
  echo   Drag one or more PDF files onto this .bat file.
  echo.
  pause
  exit /b 1
)

rem ---------- locate a Python 3 interpreter ----------
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo.
  echo   Python 3 was not found.
  echo   Install it from https://www.python.org/downloads/  ^(tick
  echo   "Add python.exe to PATH" during setup^), then drag a PDF again.
  echo.
  pause
  exit /b 1
)

rem ---------- make sure PyMuPDF is available ----------
%PY% -c "import pymupdf" >nul 2>nul
if errorlevel 1 (
  echo   Installing PyMuPDF - this happens only once...
  %PY% -m pip install --quiet pymupdf
  %PY% -c "import pymupdf" >nul 2>nul
  if errorlevel 1 (
    rem PyPI can be slow or unreachable; try a mirror before giving up.
    echo   Retrying with a domestic mirror...
    %PY% -m pip install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple pymupdf
    %PY% -c "import pymupdf" >nul 2>nul
  )
  if errorlevel 1 (
    echo.
    echo   Could not install PyMuPDF automatically.
    echo   Run this by hand:  %PY% -m pip install pymupdf
    echo.
    pause
    exit /b 1
  )
)

rem ---------- export every dropped file ----------
:loop
if "%~1"=="" goto done
echo.
echo ===================================================================
echo   %~nx1
echo ===================================================================
%PY% "%SCRIPT%" --pdf "%~f1" --open
shift
goto loop

:done
echo.
echo   Finished. Results are in the "pencil-export" folder next to
echo   each PDF (never in the PDF itself).
echo.
pause
