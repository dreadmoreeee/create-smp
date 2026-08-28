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

# Mods declarados a mano porque no estan en Modrinth (ver extras.json).
$Extras = @()
$rutaExtras = Join-Path $PSScriptRoot 'extras.json'
if (Test-Path $rutaExtras) {
    try {
        $Extras = @((Get-Content $rutaExtras -Raw | ConvertFrom-Json).mods)
        Write-Host "extras.json: $($Extras.Count) mod(s) fuera de Modrinth" -ForegroundColor Cyan
    } catch {
        Write-Host "extras.json no se pudo leer: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-Sha512 ($ruta) {
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $fs  = [System.IO.File]::OpenRead($ruta)
    try   { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

# El minimo de Fabric Loader no se pone a mano: se saca del propio pack,
# leyendo el "fabricloader" que declara cada fabric.mod.json y quedandose con
# el mas alto. Ponerlo a ojo (p.ej. la version que tenga el servidor) rechaza
# a jugadores cuyo loader vale de sobra.
function Get-LoaderMinimo ($carpeta) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $max = [version]'0.0.0'
    foreach ($j in Get-ChildItem $carpeta -Filter *.jar -File) {
        try {
            $z = [IO.Compression.ZipFile]::OpenRead($j.FullName)
            $e = @($z.Entries | Where-Object { $_.FullName -eq 'fabric.mod.json' })[0]
            if ($e) {
                $sr  = New-Object IO.StreamReader($e.Open())
                $txt = $sr.ReadToEnd(); $sr.Close()
                # Hay que parsear el JSON de verdad: muchos jars escriben el
                # ">=" escapado como >=, y un regex sobre el texto
                # crudo se comeria el "003" de la secuencia como si fuera la
                # version.
                $dep = $null
                try { $dep = ($txt | ConvertFrom-Json).depends.fabricloader } catch { }
                if ($dep) {
                    $m = [regex]::Match([string]$dep, '([0-9]+(\.[0-9]+)*)')
                    if ($m.Success) {
                        try { $v = [version]$m.Groups[1].Value } catch { $v = $null }
                        if ($v -and $v -gt $max) { $max = $v }
                    }
                }
            }
            $z.Dispose()
        } catch { }
    }
    return $max.ToString()
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
    $deExtras    = New-Object System.Collections.ArrayList

    foreach ($h in ($porHash.Keys | Sort-Object { $porHash[$_] })) {
        $nombreJar = $porHash[$h]
        $v = $encontrados[$h]

        if ($null -eq $v) {
            # No esta en Modrinth. Puede que sea uno de los declarados a mano.
            $ex = @($Extras | Where-Object { $_.file -eq $nombreJar })[0]
            if ($null -eq $ex) { [void]$sinResolver.Add($nombreJar); continue }
            [void]$mods.Add([ordered]@{
                file    = $nombreJar
                source  = $ex.source
                page    = $ex.page
                sha512  = $h
                size    = (Get-Item (Join-Path $carpeta $nombreJar)).Length
                url     = $ex.url
            })
            [void]$deExtras.Add($nombreJar)
            continue
        }

        $archivo = @($v.files | Where-Object { $_.hashes.sha512 -eq $h })[0]
        [void]$mods.Add([ordered]@{
            file       = $nombreJar
            project_id = $v.project_id
            version_id = $v.id
            version    = $v.version_number
            sha512     = $h
            size       = $archivo.size
            url        = $archivo.url
        })
    }

    if ($deExtras.Count -gt 0) {
        Write-Host "   fuera de Modrinth, tomados de extras.json:" -ForegroundColor Cyan
        foreach ($s in $deExtras) { Write-Host "      + $s" -ForegroundColor Cyan }
    }

    if ($sinResolver.Count -gt 0) {
        Write-Host "   AVISO: estos .jar no estan en Modrinth NI en extras.json," -ForegroundColor Yellow
        Write-Host "   asi que nadie los podra descargar:" -ForegroundColor Yellow
        foreach ($s in $sinResolver) { Write-Host "      - $s" -ForegroundColor Yellow }
        Write-Host "   Anadelos a install\extras.json con su url de descarga directa." -ForegroundColor Yellow
    }

    $loaderMin = Get-LoaderMinimo $carpeta
    Write-Host "   Fabric Loader minimo que exige el pack: $loaderMin"

    return [ordered]@{
        name              = $nombre
        description       = $descripcion
        minecraft         = '1.20.1'
        loader            = 'fabric'
        loader_version_min= $loaderMin
        generated         = (Get-Date -Format 'yyyy-MM-dd')
        mod_count         = $mods.Count
        mods              = $mods
    }
}

if (-not (Test-Path $Salida)) { [void](New-Item -ItemType Directory -Path $Salida) }

$cli = Build-Manifest $ClientMods 'Create SMP - Cliente'  'Mods que debe tener cada jugador'
$srv = Build-Manifest $ServerMods 'Create SMP - Servidor' 'Mods instalados en el servidor'

# UTF-8 SIN BOM. Set-Content -Encoding UTF8 en PowerShell 5.1 escribe el BOM,
# y aunque en local Get-Content lo quita solo, al bajar el archivo por HTTP
# llega como U+FEFF y ConvertFrom-Json falla con "Invalid JSON primitive".
$sinBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Salida 'modpack.json'),     ($cli | ConvertTo-Json -Depth 6), $sinBom)
[IO.File]::WriteAllText((Join-Path $Salida 'server-mods.json'), ($srv | ConvertTo-Json -Depth 6), $sinBom)

Write-Host ""
Write-Host "Listo:" -ForegroundColor Green
Write-Host "   modpack/modpack.json      $($cli.mod_count) mods"
Write-Host "   modpack/server-mods.json  $($srv.mod_count) mods"
Write-Host ""
Write-Host "Ahora sube los cambios:" -ForegroundColor Cyan
Write-Host '   git add -A; git commit -m "actualizar lista de mods"; git push'
