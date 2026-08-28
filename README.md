# Create SMP — Minecraft 1.20.1 Fabric

Configuración y lista de mods del servidor.

**Este repo no contiene ningún `.jar`.** Guarda una lista con la versión exacta
de cada mod y su enlace de descarga en Modrinth; el instalador los baja de ahí.
Así el repo pesa unos pocos cientos de KB en vez de 400 MB, no se redistribuye
software de terceros, y cada actualización es un diff legible.

---

## Para jugadores: instalar o actualizar los mods

1. Ten instalado **Fabric 1.20.1** ([instalador oficial](https://fabricmc.net/use/installer/)).
2. Cierra Minecraft por completo.
3. Descarga este repo (botón verde **Code → Download ZIP**) y descomprímelo.
4. Entra en la carpeta `install/` y ejecuta **`ACTUALIZAR.bat`**.

El script hace todo esto solo:

- busca tu Minecraft en las rutas habituales (incluidas las de TLauncher) y se queda
  con la que de verdad tenga **Fabric 1.20.1**;
- reconoce el perfil por sus librerías, no por el nombre de la carpeta, así que da
  igual que se llame `Fabric 1.20.1`, `fabric-loader-0.17.2-1.20.1` o lo que ponga
  TLauncher;
- comprueba que el loader sea `0.17.2` o superior (que es el mayor que exige un mod
  del pack, calculado a partir de los propios `.jar`);
- avisa si tienes perfiles de Forge u OptiFine que puedan confundirte al entrar;
- descarga la lista de mods más reciente desde GitHub;
- compara tu carpeta `mods` con esa lista, verificando cada archivo por **hash SHA-512**;
- **descarga** lo que falte y **vuelve a bajar** lo que esté corrupto o desactualizado;
- **quita** los mods que sobren (los mueve a `mods-quitados/`, no los borra);
- **respeta el mod de skins de TLauncher** (`tl_skin_cape*`), que el propio launcher
  instala solo y que los jugadores no premium necesitan para verse las skins;
- **limpia la caché `.bobby`** del mapa.

Es seguro ejecutarlo las veces que quieras: si ya está todo bien, no toca nada.

### Si no encuentra tu carpeta

Busca en `%APPDATA%\.minecraft` y en la de TLauncher. Si usas otra ruta:

```
powershell -ExecutionPolicy Bypass -File install\sync.ps1 -MinecraftDir "C:\ruta\a\.minecraft"
```

---

## Para el admin: añadir o quitar un mod

1. Mete o saca el `.jar` de `mods/` (servidor) y de `client-pack/mods/` (lo que reciben los jugadores).
2. Regenera la lista:
   ```
   powershell -ExecutionPolicy Bypass -File install\generar-manifest.ps1
   ```
3. Sube el cambio:
   ```
   git add -A
   git commit -m "añadir <mod>"
   git push
   ```

A partir de ese momento, cuando cualquiera ejecute `ACTUALIZAR.bat` recibirá el cambio.
No hay que repartir ningún zip.

> El generador avisa si algún `.jar` no existe en Modrinth. Esos no se pueden
> descargar automáticamente y habría que repartirlos aparte.

### Mods que el sincronizador no debe tocar

Algunos mods los instala el propio launcher y no deben quitarse aunque no estén
en la lista. Están en la variable `$Protegidos` al principio de `install/sync.ps1`:

```powershell
$Protegidos = @('tl_skin_cape*', 'tlskincape*', 'TLauncher*')
```

Son patrones de nombre de archivo (comodín `*`). Si aparece otro caso parecido,
se añade ahí.

---

## Qué hay en el repo

| Ruta | Qué es |
|---|---|
| `modpack/modpack.json` | lista de mods del **cliente**, con versión, tamaño, hash y URL |
| `modpack/server-mods.json` | lo mismo para el **servidor** |
| `install/ACTUALIZAR.bat` | lo que ejecutan los jugadores |
| `install/sync.ps1` | la lógica real del sincronizador |
| `install/generar-manifest.ps1` | regenera las listas tras cambiar mods |
| `config/` | configuración de los mods del servidor |
| `datapacks/` | datapacks propios (nivel base de LevelZ, densidad de estructuras) |
| `server.properties.example` | ajustes del servidor, sin datos propios |
| `start.bat` | arranque del servidor (16 GB, flags de Aikar) |

---

## Qué NO se sube nunca

El `.gitignore` ignora **todo** por defecto y solo permite las rutas de la tabla
de arriba. Queda fuera a propósito:

- `world/` — el mundo entero (los datapacks propios se versionan aparte, en `datapacks/`)
- `logs/` — contienen las **IP de los jugadores** (`log-ips=true`)
- `whitelist.json`, `ops.json`, `usercache.json`, `banned-*.json` — nombres y UUID
- `config/skinrestorer/mojang_profile_cache.json` — nombres y UUID reales
- `config/resourceful-config-web.json` — contraseña generada del panel web
- `server.properties` — lleva la contraseña de RCON (se sube `.example` con el campo vacío)
- `config/voicechat/voicechat-server.properties` — dirección del túnel de playit
  (se sube `.example` con el campo vacío)
- `mods/`, `client-pack/`, `jdk-*/`, `libraries/` y cualquier `.jar` o `.zip`

Antes del primer `push`, comprueba qué se va a subir:

```
git status --short
git ls-files | more
```
