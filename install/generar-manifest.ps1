# =====================================================================
#  Create SMP - regenerar la lista de mods
#
#  Ejecutalo EN EL SERVIDOR cada vez que anadas o quites un mod.
#  Lee las carpetas de mods, busca cada .jar en Modrinth por su hash y
#  reescribe modpack/modpack.json y modpack/server-mods.json.
#
#  Uso:   powershell -ExecutionPolicy Bypass -File generar-manifest.ps1
# =====================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz       = Split-Path -Parent $PSScriptRoot
$ClientMods = Join-Path $Raiz 'client-pack\mods'
$ServerMods = Join-Path $Raiz 'mods'
$Salida     = Join-Path $Raiz 'modpack'

function Get-Sha512 ($ruta) {
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $fs  = [System.IO.File]::OpenRead($ruta)
    try   { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Build-Manifest ($carpeta, $nombre, $descripcion) {
    Write-Host ""
    Write-Host "== $nombre ==" -ForegroundColor Cyan

    $jars = @(Get-ChildItem $carpeta -Filter *.jar -File | Sort-Object Name)
    Write-Host "   $($jars.Count) .jar encontrados, calculando hashes..."

    $porHash = @{}
    foreach ($j in $jars) { $porHash[(Get-Sha512 $j.FullName)] = $j.Name }

    # Modrinth acepta 100 hashes por peticion
    $encontrados = @{}
    $todos = @($porHash.Keys)
    for ($i = 0; $i -lt $todos.Count; $i += 100) {
        $lote = $todos[$i..([Math]::Min($i + 99, $todos.Count - 1))]
        $body = @{ hashes = $lote; algorithm = 'sha512' } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/version_files' `
                                  -Method Post -Body $body -ContentType 'application/json' `
                                  -Headers @{ 'User-Agent' = 'createsmp-manifest/1.0' }
        foreach ($p in $resp.PSObject.Properties) { $encontrados[$p.Name] = $p.Value }
        Write-Host "   consultados $([Math]::Min($i + 100, $todos.Count))/$($todos.Count)"
    }

    $mods = New-Object System.Collections.ArrayList
    $sinResolver = New-Object System.Collections.ArrayList

    foreach ($h in ($porHash.Keys | Sort-Object { $porHash[$_] })) {
        $v = $encontrados[$h]
        if ($null -eq $v) { [void]$sinResolver.Add($porHash[$h]); continue }
        $archivo = @($v.files | Where-Object { $_.hashes.sha512 -eq $h })[0]
        [void]$mods.Add([ordered]@{
            file       = $porHash[$h]
            project_id = $v.project_id
            version_id = $v.id
            version    = $v.version_number
            sha512     = $h
            size       = $archivo.size
            url        = $archivo.url
        })
    }

    if ($sinResolver.Count -gt 0) {
        Write-Host "   AVISO: estos .jar no estan en Modrinth y NO se podran" -ForegroundColor Yellow
        Write-Host "   descargar automaticamente:" -ForegroundColor Yellow
        foreach ($s in $sinResolver) { Write-Host "      - $s" -ForegroundColor Yellow }
    }

    return [ordered]@{
        name              = $nombre
        description       = $descripcion
        minecraft         = '1.20.1'
        loader            = 'fabric'
        loader_version_min= '0.19.3'
        generated         = (Get-Date -Format 'yyyy-MM-dd')
        mod_count         = $mods.Count
        mods              = $mods
    }
}

if (-not (Test-Path $Salida)) { [void](New-Item -ItemType Directory -Path $Salida) }

$cli = Build-Manifest $ClientMods 'Create SMP - Cliente'  'Mods que debe tener cada jugador'
$srv = Build-Manifest $ServerMods 'Create SMP - Servidor' 'Mods instalados en el servidor'

$cli | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Salida 'modpack.json')     -Encoding UTF8
$srv | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Salida 'server-mods.json') -Encoding UTF8

Write-Host ""
Write-Host "Listo:" -ForegroundColor Green
Write-Host "   modpack/modpack.json      $($cli.mod_count) mods"
Write-Host "   modpack/server-mods.json  $($srv.mod_count) mods"
Write-Host ""
Write-Host "Ahora sube los cambios:" -ForegroundColor Cyan
Write-Host '   git add -A; git commit -m "actualizar lista de mods"; git push'
