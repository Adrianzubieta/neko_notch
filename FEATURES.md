# NekoNotch · implementación y límites

Versión 0.1.1 para Intel y Apple Silicon, con macOS 14.2 o posterior. Compilación local con Command Line Tools; firma ad hoc, sin notarización.

## Panel, pantallas y configuración

El panel aparece junto al notch o en el centro superior de pantallas sin notch. Opciones permite elegir tamaño, contenido compacto y pantalla: Automática, una pantalla específica o Todas las pantallas. Hay una ventana por monitor; su expansión es independiente. Las herramientas y preferencias son compartidas. La lista de pantallas se actualiza al conectar o desconectar monitores.

Las pestañas muestran solo íconos, con nombres al pasar el mouse y etiquetas de accesibilidad. Cada sección de configuración empieza con “Mostrar pestaña”. Ocultar la pestaña no detiene sus servicios en segundo plano. Opciones sigue accesible desde el menú del gatito aunque su pestaña esté oculta. La ventana independiente de configuración permite desplazamiento vertical.

El gatito de la barra de menús se anima según el uso de CPU. El ícono del bundle se genera desde `Scripts/GenerateIcon.swift` durante la compilación.

## IA

Claude puede conectarse desde Opciones mediante una ventana WebKit en claude.ai. La sesión permanece en el almacén local de WebKit; no se exportan cookies ni tokens. Se consulta la organización y el uso cada minuto usando interfaces web que pueden cambiar. La lectura se guarda en `~/Library/Application Support/MiMac/claude-web-usage.json` con permisos 0600.

El puente `ClaudeStatusline --install` integra el statusLine de Claude Code, respalda la configuración existente y guarda los límites recibidos en `claude-code-usage.json`. La app también admite el historial local de Claude Desktop como fuente alternativa y selecciona la muestra más reciente. No garantiza recibir datos actualizados sin actividad en la fuente.

Codex se lee del final de los registros recientes de `~/.codex/sessions`, buscando eventos de cuota. No se lee `auth.json`. No se muestran ni guardan conversaciones en el historial de NekoNotch. El último evento puede corresponder a otra cuenta si cambiaste de cuenta.

El historial conserva hasta 30 días de muestras locales y muestra gráficos de las últimas 24 horas. No reconstruye períodos anteriores. El ritmo de consumo compara porcentajes y detecta reinicios; no inventa muestras, modelos ni cuotas ausentes. Los datos atrasados se señalan. El archivo es `usage-history.json` dentro de la carpeta de datos de la app.

## Bandeja de archivos

Arrastrá archivos o carpetas sobre el panel para agregarlos. La bandeja guarda referencias a los originales, sin copiarlos. Admite arrastrar hacia otras apps, copiar y mostrar en Finder. La compatibilidad de arrastrar y pegar depende del destino.

Cada elemento muestra miniatura, menú y una X para quitarlo de la bandeja sin borrar el original. No muestra el nombre en la tarjeta; la ruta está disponible al pasar el mouse. Las miniaturas se generan con Quick Look Thumbnailing, con ícono como alternativa. Tocar la miniatura o elegir “Vista previa” abre una ventana redimensionable con Quick Look. Los formatos compatibles dependen del sistema. Un original movido o borrado se marca como no disponible.

## Reproductor

Consulta Ahora suena de macOS cada tres segundos mediante MediaRemote Adapter. Muestra portada, título, artista, origen y estado según los metadatos disponibles. Los tres tamaños ajustan portada, textos, controles y espacios.

Anterior, pausa/reproducción y siguiente envían comandos al reproductor activo. La barra muestra progreso y permite cambiar la posición cuando hay duración disponible. El volumen debajo de la portada controla la salida general. No incluye letras ni cola de reproducción. No requiere una extensión del navegador; no garantiza detectar todos los sitios ni controlar varias reproducciones simultáneas.

El adaptador usa una interfaz interna de macOS y puede dejar de funcionar tras actualizaciones. Código y licencia BSD-3-Clause en `ThirdParty/MediaRemoteAdapter/`.

## Audio y mezclador por app

Core Audio permite listar salidas y modificar volumen/silencio cuando el dispositivo lo admite. Las salidas con control externo se muestran sin deslizador operativo.

El mezclador muestra apps abiertas con controles verticales e íconos. Agrupa procesos auxiliares por la app principal, incluso cuando no están registrados como aplicaciones en AppKit. Una app sin audio conserva el nivel elegido hasta que se detecta reproducción. Los cambios de procesos recrean el procesamiento con el nivel pendiente. Las apps web pueden compartir el proceso del navegador.

Un nivel inferior a 100% inicia un tap de Core Audio; puede pedir permiso de audio del sistema. El audio se procesa en memoria, sin archivos ni envío de red. El rango es 0–100%; restaurar, desactivar el mezclador o cerrar la app libera los taps. Cambiar de salida restaura los volúmenes originales.

La implementación inicial requiere salida estéreo PCM Float32, audio intercalado del tap y frecuencia coincidente. Un fallo al iniciar restaura el nivel. Si no llega señal compatible en la comprobación inicial mientras la app sigue reproduciendo, se libera el tap. La compilación no confirma compatibilidad audible con todos los dispositivos ni apps.

## Teclado y pantalla encendida

Los dos botones flotantes se pueden mostrar u ocultar en Opciones → Mac.

“Bloquear teclado” usa un filtro de eventos de sesión y requiere Accesibilidad. Descarta teclas y eventos multimedia sin guardar su contenido. Mouse y trackpad siguen funcionando. Se desbloquea con el botón o desde el menú del gatito. Si macOS interrumpe el filtro, el bloqueo se libera. No se persiste activado entre ejecuciones; no garantiza bloquear encendido ni funciones reservadas del sistema. La verificación con permiso concedido queda sujeta al equipo de destino.

“Mantener pantalla encendida” crea una aserción de energía mientras la app está abierta, sin modificar las preferencias de reposo. Empieza desactivada y se libera al desactivar o salir. No impide el reposo manual ni al cerrar la tapa.

## Portapapeles

Captura textos, enlaces e imágenes copiados después de iniciar la app. Incluye búsqueda, fijados, eliminación, pausa y límite configurable. Por defecto mantiene 50 elementos en memoria y no persiste. La persistencia opcional usa `clipboard.json`; al desactivarla elimina ese archivo local. No vacía el portapapeles del sistema.

Se omiten archivos y contenido con marcadores conocidos de sensibilidad o transitoriedad, sin garantizar detectar secretos sin marcar. Texto hasta 200 KB e imágenes PNG hasta 5 MB. Los fijados no se descartan automáticamente.

## Mac y Homebrew

Mac muestra batería/carga, memoria, disco y sistema; se actualiza periódicamente.

Brew consulta fórmulas y casks, búsqueda y paquetes con actualizaciones. “Buscar actualizaciones” ejecuta `brew update`. Actualizar y desinstalar requieren elegir el paquete y confirmar. No usa `--force`, `--ignore-dependencies` ni `--zap`. Si Homebrew pide contraseña o rechaza una dependencia, informa el error. No se verificaron actualizaciones ni desinstalaciones reales como parte de esta preparación.

## Distribución

`./build.sh` genera `build/NekoNotch.app`; `./package.sh` genera ZIP y SHA-256 en `dist/`. El ZIP incluye ícono, adaptador y puente de Claude Code. Los scripts no publican en GitHub ni instalan la app automáticamente. El bundle conserva `local.mimac.monitor` para mantener preferencias.

Los datos personales y la sesión de WebKit quedan fuera del repositorio. La firma local permite verificar la integridad del bundle, pero no sustituye Developer ID ni notarización. Se requiere validación adicional en otros equipos y versiones de macOS.
