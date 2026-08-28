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
