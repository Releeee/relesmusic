# Rele's Music

App de música personal para iPhone: busca y reproduce canciones y remixes de YouTube,
crea playlists, importa tus playlists de Apple Music y sigue sonando con la pantalla apagada.

## Qué hace

- **Buscar** en YouTube (canciones, remixes, lo que sea) o **pegar un enlace** de YouTube.
- **Playlists**: crear, renombrar, reordenar, borrar canciones, reproducir o aleatorio.
- **Importar de Apple Music**: lee tus playlists del iPhone y busca cada canción en YouTube.
  ⚠️ Hazlo **antes** de cancelar Apple Music, porque al cancelar desaparecen de tu biblioteca.
- **Segundo plano**: suena con la pantalla bloqueada, con controles en la pantalla de bloqueo
  y en los auriculares. Repetir, aleatorio y cola.

---

## Paso 1 — Subir el proyecto a GitHub (una vez)

1. Crea una cuenta en <https://github.com> (gratis).
2. Pulsa **New repository** → nombre `relesmusic` → elige **Public** → **Create repository**.
   - *Public* = compilaciones ilimitadas gratis. *Private* también funciona,
     pero solo tienes unas ~20 compilaciones gratis al mes.
3. En la página del repositorio vacío pulsa **uploading an existing file** y arrastra
   **todo el contenido de esta carpeta** (incluida la carpeta `.github`).
   - Si la carpeta `.github` no se sube al arrastrar (Windows a veces la oculta),
     instala **GitHub Desktop** (<https://desktop.github.com>) y publica la carpeta desde ahí.
4. Pulsa **Commit changes**.

## Paso 2 — Compilar la app (automático)

1. En tu repositorio, ve a la pestaña **Actions**.
2. Verás "Compilar IPA" en marcha (tarda ~5-10 min). Si no arranca, pulsa
   **Compilar IPA → Run workflow**.
3. Cuando salga el ✅, entra en la ejecución y descarga **RelesMusic-ipa** (abajo, en *Artifacts*).
4. Descomprime el `.zip`: dentro está `RelesMusic.ipa`. Pásalo al iPhone (AirDrop no hay en Windows:
   usa iCloud Drive, Google Drive o envíatelo por Telegram/WhatsApp y guárdalo en *Archivos*).

Si sale ❌, abre el paso que falló, copia el error y pásamelo para arreglarlo.

## Paso 3 — Instalar SideStore en el iPhone (una vez)

SideStore firma la app con tu Apple ID gratis y la renueva desde el propio iPhone.
Sigue la guía oficial, que está siempre actualizada: <https://docs.sidestore.io>

En resumen:
1. En el iPhone: **Ajustes › Privacidad y seguridad › Modo de desarrollador** → activar (se reinicia).
2. En el PC con Windows: sigue la guía para instalar SideStore en el iPhone con tu Apple ID
   (solo hace falta el PC esta vez).
3. Instala la app VPN que indica la guía (la usa SideStore para renovar sin PC).

## Paso 4 — Instalar Rele's Music

1. Abre **SideStore** → pestaña **My Apps** → **+** → elige `RelesMusic.ipa`.
2. Primera vez: **Ajustes › General › VPN y gestión de dispositivos** → confía en tu Apple ID.

## Cada 7 días

Abre SideStore (con su VPN activada) → **My Apps** → **Refresh All**. Listo.
Si se te pasa, la app no abre pero **no pierdes nada**: renuevas y vuelve con tus playlists.

## Actualizar la app

Cuando cambiemos el código, súbelo a GitHub, descarga la nueva `.ipa` de *Actions*
e instálala encima desde SideStore. Tus playlists se mantienen.

---

### Notas

- La música se reproduce desde YouTube por streaming (gasta datos, sin descargas offline de momento).
- YouTube cambia su sistema a menudo. Si un día deja de sonar, normalmente basta con
  volver a compilar (la app usa la última versión de la librería YouTubeKit).
- Uso personal. Reproducir YouTube fuera de su app va contra sus condiciones de uso.
