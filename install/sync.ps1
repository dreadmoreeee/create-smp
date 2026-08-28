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
    [string]$LogPath      = "",
    [switch]$Offline,
    [switch]$NoPause,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# URL cruda del manifest en GitHub. Si cambias de repo, cambia esto.
$ManifestUrl = 'https://raw.githubusercontent.com/dreadmoreeee/create-smp/main/modpack/modpack.json'

$MC_VERSION      = '1.20.1'
# Minimo REAL: es el mayor "fabricloader" que declara algun mod del pack
# (lo dice generar-manifest.ps1). No poner aqui la version que tenga el
# servidor: rechazaria a jugadores cuyo loader vale perfectamente.
$LOADER_MIN      = '0.17.2'
$BackupDirName   = 'mods-quitados'

# Mods que NO son del pack pero que tampoco hay que tocar.
# TLauncher inyecta solo su mod de skins/capas en la carpeta mods; si se lo
# quitamos, los jugadores no premium pierden las skins, y ademas TLauncher lo
# vuelve a poner al arrancar -> el script lo quitaria una y otra vez.
$Protegidos = @(
    'tl_skin_cape*',      # TLauncher - skins y capas
    'tlskincape*',
    'TLauncher*'
)

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

# ---------------------------------------------------------------- registro
# Todo lo que sale por pantalla se guarda tambien en un archivo, para poder
# mandarlo cuando algo falle en el ordenador de otro.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot 'actualizar-log.txt'
    # si la carpeta no deja escribir (descargado a una ruta protegida, o
    # abierto desde dentro del .zip), se usa la carpeta temporal
    try {
        $prueba = Join-Path $PSScriptRoot ('.w' + [guid]::NewGuid().ToString('N').Substring(0,6))
        Set-Content $prueba -Value 'x' -EA Stop
        Remove-Item $prueba -Force -EA SilentlyContinue
    } catch {
        $LogPath = Join-Path $env:TEMP 'create-smp-actualizar-log.txt'
    }
}

$script:LogOn = $false
try { Start-Transcript -Path $LogPath -Force -EA Stop | Out-Null; $script:LogOn = $true } catch { }

function Cerrar-Log {
    if ($script:LogOn) { try { Stop-Transcript | Out-Null } catch { } ; $script:LogOn = $false }
}

function Fin ($code) {
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "  Se guardo un registro completo en:" -ForegroundColor Yellow
        Write-Host "     $LogPath" -ForegroundColor Yellow
        Write-Host "  Mandaselo a quien lleva el servidor." -ForegroundColor Yellow
    }
    Cerrar-Log
    if (-not $NoPause) {
        Write-Host ""
        Write-Host "Pulsa una tecla para cerrar..." -ForegroundColor DarkGray
        try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
    exit $code
}

# Cualquier error que no este previsto acaba aqui en vez de cerrar la ventana
# de golpe sin decir nada.
trap {
    Write-Host ""
    Write-Host "  [ERROR] Fallo inesperado. Esto es lo que hay que mandar:" -ForegroundColor Red
    Write-Host "     $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host "     linea $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    }
    if ($_.ScriptStackTrace) { Write-Host "     $($_.ScriptStackTrace)" -ForegroundColor DarkGray }
    Fin 1
}

Title "Create SMP  -  sincronizador de mods  (Minecraft $MC_VERSION Fabric)"

# Datos del equipo: casi todos los fallos raros salen de aqui.
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -EA Stop } catch { }
Say "  fecha       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say "  equipo      : $(if ($os) { "$($os.Caption) build $($os.BuildNumber)" } else { 'desconocido' })"
Say "  PowerShell  : $($PSVersionTable.PSVersion)  ($(if ([Environment]::Is64BitProcess) { '64' } else { '32' }) bits)"
Say "  politica    : $(try { Get-ExecutionPolicy } catch { 'n/d' })"
Say "  APPDATA     : $env:APPDATA"
Say "  script      : $PSScriptRoot"
Say "  registro    : $LogPath"

# ------------------------------------------------- 1. Localizar .minecraft
# Un perfil de Fabric se reconoce por sus LIBRERIAS, no por el nombre de la
# carpeta: TLauncher, el instalador oficial y CurseForge lo nombran distinto
# ("Fabric 1.20.1", "fabric-loader-0.17.2-1.20.1", "1.20.1-fabric"...).
# La libreria net.fabricmc:intermediary:<version> siempre lleva la version
# del juego, asi que es el marcador fiable.
function Get-PerfilesFabric ($raiz) {
    $res = @()
    $vd = Join-Path $raiz 'versions'
    if (-not (Test-Path $vd)) { return $res }
    foreach ($dir in @(Get-ChildItem $vd -Directory -EA SilentlyContinue)) {
        foreach ($js in @(Get-ChildItem $dir.FullName -Filter *.json -File -EA SilentlyContinue)) {
            try { $txt = Get-Content $js.FullName -Raw -EA Stop } catch { continue }
            $m = [regex]::Match($txt, 'net\.fabricmc:fabric-loader:([0-9][0-9\.]*)')
            if (-not $m.Success) { continue }
            $esVersion = ($txt -match [regex]::Escape("net.fabricmc:intermediary:$MC_VERSION")) -or
                         ($txt -match ('"inheritsFrom"\s*:\s*"' + [regex]::Escape($MC_VERSION) + '"')) -or
                         ($dir.Name -match [regex]::Escape($MC_VERSION))
            if (-not $esVersion) { continue }
            $res += [pscustomobject]@{
                Nombre = $dir.Name
                Loader = $m.Groups[1].Value.TrimEnd('.')
            }
            break
        }
    }
    return $res
}

if ([string]::IsNullOrWhiteSpace($MinecraftDir)) {
    $candidatos = @(
        (Join-Path $env:APPDATA '.minecraft'),
        (Join-Path $env:APPDATA '.tlauncher\legacy\Minecraft\game'),
        (Join-Path $env:APPDATA '.tlauncher\Minecraft\game'),
        (Join-Path $env:USERPROFILE '.minecraft'),
        (Join-Path $env:USERPROFILE 'AppData\Roaming\.minecraft'),
        (Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances')
    ) | Select-Object -Unique
} else {
    $candidatos = @($MinecraftDir)
}

# Se elige la carpeta que REALMENTE tiene un Fabric de esta version, no la
# primera que tenga un 'versions' (habia gente con un .minecraft viejo y
# vacio al lado del bueno de TLauncher).
$perfiles = @()
$elegida  = $null
$informe  = @()
foreach ($c in $candidatos) {
    if (-not (Test-Path $c)) { $informe += "$c  ->  no existe"; continue }
    $p = @(Get-PerfilesFabric $c)
    if ($p.Count -gt 0) {
        $elegida = $c; $perfiles = $p
        $informe += "$c  ->  $($p.Count) perfil(es) de Fabric $MC_VERSION"
        break
    }
    $otras = @(Get-ChildItem (Join-Path $c 'versions') -Directory -EA SilentlyContinue)
    $informe += "$c  ->  $($otras.Count) version(es), ninguna Fabric $MC_VERSION"
}

if ($null -eq $elegida) {
    Bad "No encontre ninguna instalacion con Fabric $MC_VERSION."
    Say ""
    Say "  Carpetas revisadas:"
    foreach ($l in $informe) { Say "     $l" }
    Say ""
    foreach ($c in $candidatos) {
        $otras = @(Get-ChildItem (Join-Path $c 'versions') -Directory -EA SilentlyContinue)
        if ($otras.Count -gt 0) {
            Say "  Versiones que hay en $c :"
            foreach ($o in $otras) { Say "     - $($o.Name)" }
            Say ""
            break
        }
    }
    Say "  En TLauncher: pestana de versiones, marca 'Fabric' y elige $MC_VERSION."
    Say "  O instalalo desde  https://fabricmc.net/use/installer/"
    Say ""
    Say "  Si tu Minecraft esta en otra ruta, pasala a mano:"
    Say "     powershell -ExecutionPolicy Bypass -File sync.ps1 -MinecraftDir `"C:\ruta\a\.minecraft`""
    Fin 1
}
$MinecraftDir = $elegida
Ok ".minecraft: $MinecraftDir"
# el recorrido completo queda siempre en el registro
foreach ($l in $informe) { Write-Host "          $l" -ForegroundColor DarkGray }

$ModsDir = Join-Path $MinecraftDir 'mods'
if (-not (Test-Path $ModsDir)) { [void](New-Item -ItemType Directory -Path $ModsDir) }

# Una version anterior de este script se llevaba a mods-quitados el mod de
# skins de TLauncher. Si sigue ahi, lo devolvemos a su sitio.
$bakDir = Join-Path $MinecraftDir $BackupDirName
if (Test-Path $bakDir) {
    foreach ($f in @(Get-ChildItem $bakDir -Filter *.jar -File -EA SilentlyContinue)) {
        foreach ($p in $Protegidos) {
            if ($f.Name -like $p) {
                $destino = Join-Path $ModsDir $f.Name
                if (-not (Test-Path $destino)) {
                    Move-Item $f.FullName $destino -Force
                    Info "devuelto a mods: $($f.Name)"
                }
                break
            }
        }
    }
}

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

$loaderOk = $false
foreach ($p in $perfiles) {
    $vale = $false
    try { $vale = ([version]$p.Loader).CompareTo([version]$LOADER_MIN) -ge 0 } catch { $vale = $false }
    if ($vale) {
        Ok "perfil '$($p.Nombre)'  ->  Fabric Loader $($p.Loader)"
        $loaderOk = $true
    } else {
        Warn "perfil '$($p.Nombre)' tiene Fabric Loader $($p.Loader) (hace falta $LOADER_MIN o superior)"
    }
}
if (-not $loaderOk) {
    Bad "Ningun perfil llega a Fabric Loader $LOADER_MIN."
    Say "  En TLauncher, al elegir Fabric $MC_VERSION coge la version de loader mas alta."
    Say "  O reinstalalo desde  https://fabricmc.net/use/installer/"
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
$respetados= New-Object System.Collections.ArrayList

$i = 0
foreach ($f in $locales) {
    $i++
    Write-Host ("`r  verificando  $i/$($locales.Count) ...") -NoNewline
    if (-not $requeridos.ContainsKey($f.Name)) {
        $esProtegido = $false
        foreach ($p in $Protegidos) { if ($f.Name -like $p) { $esProtegido = $true; break } }
        if ($esProtegido) { [void]$respetados.Add($f.Name) } else { [void]$sobran.Add($f) }
        continue
    }
    if ((Get-Sha512 $f.FullName) -eq $requeridos[$f.Name].sha512) { [void]$correctos.Add($f.Name) }
    else { [void]$corruptos.Add($f.Name) }
}
Write-Host "`r                                          `r" -NoNewline

$faltan = @($pack.mods | Where-Object { $correctos -notcontains $_.file })

Ok      "correctos:  $($correctos.Count)"
if ($faltan.Count    -gt 0) { Warn "por descargar: $($faltan.Count)" }
if ($corruptos.Count -gt 0) { Warn "corruptos (se rebajaran): $($corruptos.Count)" }
if ($sobran.Count    -gt 0) { Warn "sobran (se quitaran): $($sobran.Count)" }
if ($respetados.Count -gt 0) {
    Info "no son del pack pero los dejo en su sitio: $($respetados.Count)"
    foreach ($r in $respetados) { Say "     . $r" }
}

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
# Lo correcto no es contar archivos (puede haber protegidos de mas), sino
# comprobar que esta cada uno de los que pide el server.
$hay      = @{}
$finalJar = @(Get-ChildItem $ModsDir -Filter *.jar -File -EA SilentlyContinue)
foreach ($f in $finalJar) { $hay[$f.Name] = $true }
$ausentes = @($pack.mods | Where-Object { -not $hay.ContainsKey($_.file) })

Title "RESUMEN"
Say "  mods del pack instalados: $($pack.mods.Count - $ausentes.Count) de $($pack.mods.Count)"
if ($respetados.Count -gt 0) { Say "  ademas, respetados      : $($respetados.Count)  ($($respetados -join ', '))" }
Say "  .jar totales en la carpeta: $($finalJar.Count)"
Say ""
if ($ausentes.Count -eq 0) {
    Ok "Todo listo. Abre Minecraft con el perfil FABRIC $MC_VERSION y conectate."
    Fin 0
} else {
    Bad "Faltan $($ausentes.Count) mod(s):"
    foreach ($a in $ausentes) { Say "     - $($a.file)" }
    Warn "Vuelve a ejecutar el .bat; si sigue igual, avisa."
    Fin 1
}
