# =====================================================================
#  Create SMP - Sincronizador de mods
#  Compara la carpeta mods contra la lista oficial del repo:
#    - descarga lo que falta
#    - borra lo que sobra (con respaldo)
#    - verifica la version de Minecraft / Fabric
#    - limpia la cache .bobby
# =====================================================================

[CmdletBinding()]
param(
    [string]$MinecraftDir = "",
    [string]$Manifest     = "",
    [switch]$Offline,
    [switch]$NoPause,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# URL cruda del manifest en GitHub. Si cambias de repo, cambia esto.
$ManifestUrl = 'https://raw.githubusercontent.com/__USUARIO__/__REPO__/main/modpack/modpack.json'

$MC_VERSION      = '1.20.1'
$LOADER_MIN      = '0.19.3'
$BackupDirName   = 'mods-quitados'

# ---------------------------------------------------------------- UI
function Say  ($m) { Write-Host $m }
function Ok   ($m) { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Info ($m) { Write-Host "  [..]    $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  [ERROR] $m" -ForegroundColor Red }

function Title ($m) {
    Write-Host ""
    Write-Host "=======================================================" -ForegroundColor DarkGray
    Write-Host "  $m" -ForegroundColor White
    Write-Host "=======================================================" -ForegroundColor DarkGray
}

function Fin ($code) {
    if (-not $NoPause) {
        Write-Host ""
        Write-Host "Pulsa una tecla para cerrar..." -ForegroundColor DarkGray
        try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
    exit $code
}

Title "Create SMP  -  sincronizador de mods  (Minecraft $MC_VERSION Fabric)"

# ------------------------------------------------- 1. Localizar .minecraft
if ([string]::IsNullOrWhiteSpace($MinecraftDir)) {
    $candidatos = @(
        (Join-Path $env:APPDATA '.minecraft'),
        (Join-Path $env:APPDATA '.tlauncher\legacy\Minecraft\game'),
        (Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances')
    )
    foreach ($c in $candidatos) {
        if (Test-Path (Join-Path $c 'versions')) { $MinecraftDir = $c; break }
    }
}
if ([string]::IsNullOrWhiteSpace($MinecraftDir) -or -not (Test-Path $MinecraftDir)) {
    Bad "No encontre la carpeta .minecraft."
    Say  "  Ejecutalo asi, con la ruta correcta entre comillas:"
    Say  "     powershell -ExecutionPolicy Bypass -File sync.ps1 -MinecraftDir `"C:\ruta\a\.minecraft`""
    Fin 1
}
Ok ".minecraft: $MinecraftDir"

$ModsDir = Join-Path $MinecraftDir 'mods'
if (-not (Test-Path $ModsDir)) { [void](New-Item -ItemType Directory -Path $ModsDir) }

# ------------------------------------------------- 1b. Minecraft abierto?
# Solo bloquea si el juego abierto usa ESTA carpeta (si no, los .jar estarian
# bloqueados por Windows y las descargas fallarian a medias).
if (-not $Force) {
    $raiz  = (Resolve-Path $MinecraftDir).Path.TrimEnd('\')
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe'" -EA SilentlyContinue)
    $chocan = @($procs | Where-Object {
        ("$($_.CommandLine) $($_.ExecutablePath)") -like "*$raiz*"
    })
    if ($chocan.Count -gt 0) {
        Bad "Minecraft esta abierto usando esta misma carpeta."
        Say "  Cierralo por completo (incluido el launcher) y vuelve a ejecutar esto."
        Say "  Si estas seguro de que no, ejecuta el .bat otra vez anadiendo:  -Force"
        Fin 1
    }
    if ($procs.Count -gt 0) {
        Warn "hay un Minecraft abierto, pero de otra carpeta. Continuo."
    }
}

# ------------------------------------------------- 2. Verificar version
Title "1/5  Comprobando la version de Minecraft"

$versionsDir = Join-Path $MinecraftDir 'versions'
$perfiles = @()
if (Test-Path $versionsDir) {
    $perfiles = @(Get-ChildItem $versionsDir -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'fabric' -and $_.Name -match [regex]::Escape($MC_VERSION) })
}

if ($perfiles.Count -eq 0) {
    Bad "No hay ningun perfil de Fabric $MC_VERSION instalado."
    Say ""
    Say "  Instala Fabric antes de continuar:"
    Say "     https://fabricmc.net/use/installer/   ->  version $MC_VERSION"
    Say "  (o en TLauncher elige la version 'Fabric $MC_VERSION')"
    Fin 1
}

$loaderOk = $false
foreach ($p in $perfiles) {
    $j = Join-Path $p.FullName "$($p.Name).json"
    if (-not (Test-Path $j)) { continue }
    $txt = Get-Content $j -Raw
    $m = [regex]::Match($txt, 'net\.fabricmc:fabric-loader:([0-9][0-9\.]*)')
    if (-not $m.Success) { continue }
    $v = $m.Groups[1].Value
    $cmp = ([version]$v).CompareTo([version]$LOADER_MIN)
    if ($cmp -ge 0) {
        Ok "perfil '$($p.Name)'  ->  Fabric Loader $v"
        $loaderOk = $true
    } else {
        Warn "perfil '$($p.Name)' tiene Fabric Loader $v (hace falta $LOADER_MIN o superior)"
    }
}
if (-not $loaderOk) {
    Bad "Ningun perfil llega a Fabric Loader $LOADER_MIN."
    Say "  Reinstala Fabric $MC_VERSION desde https://fabricmc.net/use/installer/"
    Fin 1
}

foreach ($mal in @('forge', 'neoforge', 'optifine')) {
    $hay = @(Get-ChildItem $versionsDir -Directory -EA SilentlyContinue | Where-Object { $_.Name -match $mal })
    if ($hay.Count -gt 0) {
        Warn "tienes perfiles de $mal instalados. Al entrar al server elige el perfil FABRIC $MC_VERSION."
    }
}

# ------------------------------------------------- 3. Obtener la lista
Title "2/5  Descargando la lista oficial de mods"

$json = $null
if (-not [string]::IsNullOrWhiteSpace($Manifest) -and (Test-Path $Manifest)) {
    $json = Get-Content $Manifest -Raw
    Ok "usando lista local: $Manifest"
} else {
    if (-not $Offline) {
        try {
            $json = (Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 30).Content
            Ok "lista descargada de GitHub"
        } catch {
            Warn "no pude bajar la lista de GitHub ($($_.Exception.Message))"
        }
    }
    if ($null -eq $json) {
        $local = Join-Path (Split-Path -Parent $PSScriptRoot) 'modpack\modpack.json'
        if (Test-Path $local) {
            $json = Get-Content $local -Raw
            Ok "usando la copia local del repo"
        }
    }
}
if ($null -eq $json) {
    Bad "No consegui la lista de mods (ni de GitHub ni local)."
    Fin 1
}

$pack = $json | ConvertFrom-Json
$requeridos = @{}
foreach ($m in $pack.mods) { $requeridos[$m.file] = $m }
Ok "$($pack.mods.Count) mods en la lista  (generada el $($pack.generated))"

# ------------------------------------------------- 4. Comparar
Title "3/5  Comparando con tu carpeta mods"

function Get-Sha512 ($ruta) {
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $fs  = [System.IO.File]::OpenRead($ruta)
    try   { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

$locales = @(Get-ChildItem $ModsDir -Filter *.jar -File -EA SilentlyContinue)
Info "tienes $($locales.Count) .jar instalados"

$correctos = New-Object System.Collections.ArrayList
$sobran    = New-Object System.Collections.ArrayList
$corruptos = New-Object System.Collections.ArrayList

$i = 0
foreach ($f in $locales) {
    $i++
    Write-Host ("`r  verificando  $i/$($locales.Count) ...") -NoNewline
    if (-not $requeridos.ContainsKey($f.Name)) { [void]$sobran.Add($f); continue }
    if ((Get-Sha512 $f.FullName) -eq $requeridos[$f.Name].sha512) { [void]$correctos.Add($f.Name) }
    else { [void]$corruptos.Add($f.Name) }
}
Write-Host "`r                                          `r" -NoNewline

$faltan = @($pack.mods | Where-Object { $correctos -notcontains $_.file })

Ok      "correctos:  $($correctos.Count)"
if ($faltan.Count    -gt 0) { Warn "por descargar: $($faltan.Count)" }
if ($corruptos.Count -gt 0) { Warn "corruptos (se rebajaran): $($corruptos.Count)" }
if ($sobran.Count    -gt 0) { Warn "sobran (se quitaran): $($sobran.Count)" }

if ($faltan.Count -eq 0 -and $sobran.Count -eq 0) {
    Ok "Tu carpeta mods ya esta perfecta. No hay nada que hacer."
}

# ------------------------------------------------- 5. Quitar los que sobran
if ($sobran.Count -gt 0) {
    Title "4/5  Quitando mods que no van"
    $bak = Join-Path $MinecraftDir $BackupDirName
    if (-not (Test-Path $bak)) { [void](New-Item -ItemType Directory -Path $bak) }
    foreach ($f in $sobran) {
        Move-Item $f.FullName (Join-Path $bak $f.Name) -Force
        Say "     - $($f.Name)"
    }
    Ok "movidos a: $bak   (si algo se rompe, estan ahi)"
} else {
    Title "4/5  Quitando mods que no van"
    Ok "no sobra ninguno"
}

# ------------------------------------------------- 6. Descargar
Title "5/5  Descargando los que faltan"

if ($faltan.Count -eq 0) {
    Ok "no falta ninguno"
} else {
    $totalMB = [math]::Round((($faltan | Measure-Object -Property size -Sum).Sum) / 1MB, 1)
    Info "$($faltan.Count) archivos, $totalMB MB en total"
    Say  ""
    $n = 0; $fallos = 0
    foreach ($m in $faltan) {
        $n++
        $etq = "[$n/$($faltan.Count)] $($m.file)"
        $tmp = Join-Path $env:TEMP ("csmp_" + [guid]::NewGuid().ToString('N') + ".part")
        try {
            Invoke-WebRequest -Uri $m.url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
            if ((Get-Sha512 $tmp) -ne $m.sha512) { throw "el hash no coincide (descarga corrupta)" }
            Move-Item $tmp (Join-Path $ModsDir $m.file) -Force
            Write-Host "  [OK]    $etq" -ForegroundColor Green
        } catch {
            $fallos++
            Write-Host "  [ERROR] $etq  ->  $($_.Exception.Message)" -ForegroundColor Red
            if (Test-Path $tmp) { Remove-Item $tmp -Force -EA SilentlyContinue }
        }
    }
    if ($fallos -gt 0) {
        Say ""
        Bad "$fallos archivo(s) no se pudieron descargar. Vuelve a ejecutar el .bat para reintentar."
    }
}

# ------------------------------------------------- 7. Limpiar caches
Title "Limpiando caches del cliente"

$bobby = Join-Path $MinecraftDir '.bobby'
if (Test-Path $bobby) {
    $mb = [math]::Round((Get-ChildItem $bobby -Recurse -File -EA SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Remove-Item $bobby -Recurse -Force -EA SilentlyContinue
    Ok ".bobby borrado ($mb MB liberados)"
} else {
    Ok ".bobby no existia, nada que limpiar"
}

# ------------------------------------------------- 8. Resumen
$final = @(Get-ChildItem $ModsDir -Filter *.jar -File -EA SilentlyContinue).Count
Title "RESUMEN"
Say "  mods instalados ahora : $final"
Say "  mods que pide el server: $($pack.mods.Count)"
Say ""
if ($final -eq $pack.mods.Count) {
    Ok "Todo listo. Abre Minecraft con el perfil FABRIC $MC_VERSION y conectate."
    Fin 0
} else {
    Warn "El numero no cuadra. Vuelve a ejecutar el .bat; si sigue igual, avisa."
    Fin 1
}
