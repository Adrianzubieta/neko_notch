# NekoNotch

App nativa para macOS con información y herramientas en el notch, y un gatito en la barra de menús que corre según el CPU.

Incluye uso de Claude y Codex, historial de consumo, monitor del Mac, reproductor de medios, Homebrew, audio y mezclador por app, portapapeles, bandeja de archivos y control de pantalla encendida.

## Funciones

- **Notch personalizable:** tamaños Compacto, Normal y Grande, pestañas con íconos y un interruptor para mostrar cada una desde su sección de Opciones.
- **Varias pantallas:** selección automática, un monitor específico o todas las pantallas. Cada panel se expande de forma independiente.
- **IA:** límites de Claude y Codex, reinicios e historial local de consumo.
- **Tu Mac:** batería, memoria, disco e información del sistema.
- **Reproductor:** portada, canción, artista, progreso, anterior, pausa y siguiente; volumen general y cambio de posición cuando hay duración disponible.
- **Audio:** selector de salida, volumen general y mezclador vertical por app, con silencio y restauración. Los ajustes de apps sin audio quedan pendientes hasta reproducir.
- **Bandeja de archivos:** arrastrar y soltar, miniaturas, vista previa ampliada, copiar y mostrar en Finder. La X quita la referencia de la bandeja y conserva el original.
- **Portapapeles:** historial de textos e imágenes, búsqueda, fijados y persistencia opcional.
- **Homebrew:** consulta de paquetes, actualizaciones y desinstalación con confirmación.
- **Botones flotantes:** mantener la pantalla encendida y bloquear o desbloquear el teclado con el mouse.

## Descargar e instalar

**[Descargar NekoNotch para Mac · Apple Silicon](https://github.com/Adrianzubieta/neko_notch/raw/main/dist/NekoNotch-arm64.zip)**

Versión **0.1.1** · macOS **14.2 o posterior** · chips **M1, M2, M3, M4 y posteriores**. Esta descarga no incluye soporte para Mac Intel. No hace falta instalar Xcode ni Homebrew para abrir la app; la pestaña Brew solo funciona si Homebrew ya está instalado.

1. Descargá y descomprimí `NekoNotch-arm64.zip`.
2. Arrastrá `NekoNotch.app` a **Aplicaciones**.
3. Abrila desde Aplicaciones. Aparece el gatito en la barra de menús y el panel junto al notch.
4. En **Opciones → General**, elegí el tamaño y la pantalla. Cada sección permite mostrar u ocultar su pestaña.
5. Si activás el mezclador por app, macOS puede solicitar permiso de audio del sistema. El bloqueo de teclado requiere **Privacidad y seguridad → Accesibilidad** para NekoNotch; el mouse y el trackpad siguen funcionando.

### Primera apertura

Esta versión tiene **firma local ad hoc**; todavía no está firmada con Developer ID ni notarizada por Apple. macOS puede bloquearla al descargarla de Internet. Si confiás en esta descarga, seguí las [instrucciones oficiales de Apple para abrir apps de desarrolladores no identificados](https://support.apple.com/102445). No es necesario desactivar Gatekeeper.

Si aparece **“Apple no pudo verificar que NekoNotch no contenga software malicioso”** y descargaste la app de este repositorio:

1. Tocá **Listo** para cerrar el aviso.
2. Abrí **Ajustes del Sistema → Privacidad y seguridad**.
3. Bajá hasta **Seguridad** y tocá **Abrir igualmente** junto a NekoNotch.
4. Autenticá la acción si macOS lo solicita y confirmá con **Abrir**.

La autorización se guarda para esa app; después podés abrirla normalmente. Estos pasos corresponden al aviso de app no verificada, no a una alerta de malware detectado o de archivo dañado.

La compilación fue comprobada en el Mac de desarrollo con Apple Silicon; aún no hay pruebas en todas las versiones de macOS compatibles con el objetivo de compilación.

### Integridad de la descarga

El archivo [SHA256SUMS.txt](dist/SHA256SUMS.txt) contiene la suma de verificación del ZIP. Dentro de la carpeta donde descargaste ambos archivos podés comprobarla con:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Crear una nueva descarga

```sh
./package.sh
```

Este script compila la app y genera `dist/NekoNotch-arm64.zip` y `dist/SHA256SUMS.txt`. Los archivos de `dist/` se incluyen en el repositorio para que el enlace de descarga del README funcione al subirlo a GitHub. Después de modificar el código, regenerá y subí también esos archivos.

También podés adjuntar ambos archivos a una **GitHub Release** etiquetada `v0.1.1`. El ZIP es la app instalable; los archivos “Source code” que GitHub genera automáticamente contienen el código y no reemplazan esta descarga.

## Compilar

Requiere Apple Silicon, macOS 14.2 o posterior y las Command Line Tools de Xcode.

```sh
./build.sh
open build/NekoNotch.app
```

La compilación y el empaquetado son locales. Ningún script publica ni instala la app automáticamente.

## Estructura

- `Sources/MiMac.swift`: notch, pestañas, opciones, gatito y bandeja.
- `Sources/Features.swift`: monitor, reproductor y Homebrew.
- `Sources/Audio.swift`: salidas y volumen general.
- `Sources/Mixer.swift` y `Sources/AppMixer.m`: mezclador por app.
- `Sources/Clipboard.swift`: historial del portapapeles.
- `Sources/UsageHistory.swift`: historial y ritmo de uso de IA.
- `Sources/KeyboardLock.swift`: bloqueo del teclado y controles de desbloqueo.
- `Sources/ClaudeSession.swift`: conexión de Claude mediante WebKit.
- `Scripts/GenerateIcon.swift`: generación local del ícono de la app.
- `Resources/`: metadatos de los bundles.
- `ThirdParty/MediaRemoteAdapter/`: adaptador con licencia BSD-3-Clause incluida.
- `FEATURES.md`: notas de implementación y limitaciones.

Se conserva el identificador `local.mimac.monitor` para mantener las preferencias existentes. Los datos de usuario permanecen fuera del repositorio, en `~/Library/Application Support/MiMac/`; no se incluyen credenciales, historial de uso ni contenido del portapapeles.

## Conectar Claude

En **Opciones → IA → Conectar Claude**, iniciá sesión en la ventana de Claude y elegí tu organización si corresponde. La app consulta el uso desde esa sesión cada minuto; la autenticación permanece en el almacenamiento local de WebKit. Esta integración depende de interfaces web de Claude que pueden cambiar.

También podés usar el puente de Claude Code descrito a continuación. La app elige la lectura más reciente entre las fuentes disponibles.

## Conectar los límites de Claude Code

Después de instalar la app, ejecutá una vez:

```sh
/Applications/NekoNotch.app/Contents/Resources/ClaudeStatusline --install
```

La integración usa el campo oficial `statusLine` de Claude Code. Hace una copia de seguridad de `~/.claude/settings.json`, conserva las demás opciones y, si ya tenías una línea de estado, la encadena sin reemplazar su salida.

Después de una respuesta de Claude Code que incluya `rate_limits`, los porcentajes y reinicios se exportan a `~/Library/Application Support/MiMac/claude-code-usage.json`. NekoNotch revisa ese archivo cada 30 segundos. Los campos dependen de que Claude Code y tu plan los informen; no se rellenan con ceros si faltan. No se usa el Llavero, ningún token ni consultas adicionales a Anthropic. El archivo guarda solo los porcentajes, reinicios, fecha y una huella para evitar falsos refrescos al repetir los mismos datos.

Si la sesión de Claude Code ya estaba abierta, una nueva respuesta debería activar el puente. Si no lo hace, cerrá y reabrí esa sesión. Usar solamente Claude Desktop no actualiza esta fuente.

Documentación: [status line de Claude Code](https://code.claude.com/docs/en/statusline#rate-limit-usage).

## Permisos y límites

- **Audio del sistema:** el mezclador procesa audio en memoria con Core Audio, sin grabarlo en archivos ni enviarlo por red. Rango de 0 a 100%, sin amplificación. La compatibilidad inicial se limita a salidas estéreo PCM Float32 y frecuencias coincidentes con el tap. Las apps web pueden compartir el proceso de audio del navegador y no siempre permiten control separado.
- **Accesibilidad:** se solicita al intentar bloquear el teclado. Para desbloquearlo, tocá otra vez el botón o elegí **Activar teclado** en el menú del gatito. El bloqueo empieza desactivado al abrir la app. El botón de encendido y las funciones reservadas del sistema no se garantizan.
- **Reproductor:** depende de los metadatos de Ahora suena y de una interfaz interna de macOS. Algunas apps no informan portada o duración, o no aceptan controles.
- **IA:** Codex se obtiene de eventos locales y puede mostrar datos atrasados. Claude usa las fuentes disponibles; no se inventan límites ni fechas ausentes.
- **Datos locales:** preferencias en UserDefaults; bandeja, historial y persistencia opcional del portapapeles en `~/Library/Application Support/MiMac/`. El historial del portapapeles puede contener información privada.

La compilación y firma se verifican localmente. El control audible por app, el bloqueo del teclado y la compatibilidad con cada versión de macOS requieren pruebas en el equipo de destino. Más detalles en [FEATURES.md](FEATURES.md).

## Dependencias y licencia

[MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter), licencia BSD-3-Clause incluida en [ThirdParty/MediaRemoteAdapter/LICENSE](ThirdParty/MediaRemoteAdapter/LICENSE). La app empaquetada incluye esa licencia.

El resto del proyecto todavía no tiene una licencia de distribución definida.
