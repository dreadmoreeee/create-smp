@echo off
title Create SMP - Actualizar mods
cd /d "%~dp0"
echo.
echo   Create SMP  -  actualizador de mods
echo   ----------------------------------
echo   Esto revisa tu carpeta mods, descarga lo que falte,
echo   quita lo que sobre y limpia la cache del mapa.
echo.
echo   NO cierres esta ventana hasta que termine.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1" %*
set RC=%ERRORLEVEL%

REM Si ni siquiera se genero el registro, PowerShell no llego a arrancar y la
REM ventana se cerraria sin que nadie llegue a ver el motivo.
if not exist "%~dp0actualizar-log.txt" (
  echo.
  echo   [ERROR] No se genero ningun registro ^(codigo %RC%^).
  echo   Puede que el antivirus o la politica de Windows esten bloqueando
  echo   PowerShell. Prueba a abrir PowerShell y ejecutar esto a mano:
  echo.
  echo      powershell -ExecutionPolicy Bypass -File "%~dp0sync.ps1"
  echo.
  pause
)

REM sin esto el .bat siempre saldria con 0, porque el ultimo comando ejecutado
REM es el 'set' de arriba y ese siempre funciona
exit /b %RC%
