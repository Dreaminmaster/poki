# Guía de Poki para iPhone

[English](iphone-guide.md) | [简体中文](iphone-guide.zh-CN.md) | [繁體中文](iphone-guide.zh-TW.md) | [日本語](iphone-guide.ja.md) | [한국어](iphone-guide.ko.md) | Español

Esta guía cubre los requisitos completos del sistema, los detalles de instalación, las actualizaciones, las preguntas frecuentes, los límites conocidos y ejemplos de tareas para la app Poki para iPhone.

Consulta los cambios de cada versión en [CHANGELOG.md](../CHANGELOG.md).

## Qué necesitas

| Elemento | Requisito |
| --- | --- |
| iPhone | iOS 18 o posterior: iPhone XS, XR, SE (2.ª generación) o posterior. Las pruebas físicas se han realizado con iPhones en iOS 27. |
| Ordenador | Un Mac con macOS 14 o posterior, o un PC con Windows (x64) con Apple Devices o iTunes. La instalación mediante el script del agente en Mac también necesita Node.js 24 o posterior. |
| Cable y cuenta | Un cable USB de datos y una cuenta de Apple. Con una cuenta gratuita, la firma dura 7 días y Poki Setup puede renovarla. |
| Conexión | Una app VPN en el iPhone que dirija `10.7.0.1` al propio teléfono. Sirven LocalDevVPN, gratuita en el App Store, o Karing y Shadowrocket configuradas con las instrucciones de Poki. |
| Cuenta del modelo | Necesitas la tuya. Puedes empezar con ChatGPT Plus o Pro, introducir una clave API de Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter u OpenCode Go, o usar tu propio servidor compatible con OpenAI. La suscripción de Claude no permite iniciar sesión aquí; usa una clave API de Anthropic. |

En iOS 27 y posteriores, Poki controla el iPhone mediante servicios nativos. En iOS 18 a 26 usa una sesión XCTest, que necesita la automatización de la interfaz activada en los ajustes de desarrollador del iPhone. La app también se instala en iPad con iPadOS 18 o posterior.

La app del iPhone usa tu propia cuenta del modelo. La suscripción de tu agente de programación no conecta esa cuenta a Poki automáticamente. Si solo quieres usar Poki MCP con tu agente actual, sigue la [instalación de MCP](install.md); MCP usa el acceso al modelo de ese cliente.

## Detalles de instalación

### Instalación con un clic (recomendada)

Solo tienes que conectar y desbloquear el iPhone, iniciar sesión cuando se indique y completar los permisos del iPhone, la conexión local y la cuenta del modelo.

Dile a tu agente, por ejemplo Claude Code o Codex:

```text
Install Poki on my iPhone from https://github.com/JosssphZhou/poki
```

El agente sigue la [habilidad install-poki](../skills/install-poki/SKILL.md) y ejecuta `bin/install-iphone.mjs`, que automatiza los pasos posibles. Tú completas lo que iOS exige en persona: introducir tu cuenta de Apple en la ventana de Poki Setup del Mac, tocar Confiar en el iPhone, activar el modo de desarrollador, confiar en el desarrollador y abrir Poki. En el primer inicio, Poki pide activar el modo de automatización. Toca Continuar e introduce el código del iPhone. Si cancelas, vuelve a activar Poki para que lo pregunte de nuevo. El agente te indica qué hacer en cada paso. Una cuenta de Apple gratuita sirve.

El instalador actual selecciona Beta. Las preferencias anteriores de Stable, Alpha y Pre-alpha también se resuelven como Beta. Si no hay Beta, se detiene. Las copias antiguas de Poki Setup pueden mantener su selección anterior; comprueba la versión que muestre tu instalación.

¿No tienes Node.js 24 o usas Windows? La misma petición funciona después de instalar Poki Setup; el agente usa su herramienta de línea de comandos. También puedes copiar la petición desde su menú: `Poki > Copy Prompt for Your Agent` en Mac, o `Settings > Use an agent` en Windows.

Si GitHub devuelve 403 o 429 al consultar las versiones, suele haberse agotado el límite horario de peticiones anónimas compartido por tu red. Prueba otra red o servidor proxy, o espera una hora.

### Con Poki Setup

Descarga Poki Setup para macOS (`.dmg`) o Windows (`.exe`, aportado por [ZhehanZhang](https://github.com/ZhehanZhang)) de la [versión Beta](https://github.com/JosssphZhou/poki/releases) más reciente que incluya el instalador y sigue su ventana. Consulta los pasos en [Poki Setup](../desktop/README.md).

### Ejecuta tu primera tarea

Tras verificar la versión instalada y terminar la conexión local y la cuenta del modelo, abre Poki y envía:

```text
Crea una nota nueva en Notas titulada "Poki Demo" con estas tres líneas: Milk, Eggs, Coffee. Abre la nota al terminar. No cambies las notas existentes.
```

Comprueba la nota en Notas: el título debe ser "Poki Demo" y el contenido debe tener Milk, Eggs y Coffee en líneas separadas. Un mensaje de finalización no basta. Si falta Notas o la configuración está incompleta, termina ese paso primero. Tras una interrupción, comprueba si la nota ya existe antes de repetir la tarea.

## Preguntas frecuentes

**¿Puedo instalar Poki desde Windows?** Sí. Poki Setup para Windows instala, empareja y renueva Poki como la versión para Mac. Instala primero Apple Devices o iTunes para que el PC detecte el iPhone. Consulta [Poki Setup](../desktop/README.md).

**¿Sigo necesitando el ordenador después de instalarlo?** Para ejecutar tareas, no. Poki funciona en el iPhone. Con una cuenta gratuita, mantén Poki Setup abierto en el ordenador para renovar la firma, o inicia sesión en Poki con tu cuenta de Apple para que el iPhone la renueve. Si no puedes iniciar sesión, usa Poki Setup en el ordenador. Consulta [qué mantener en ejecución](../skills/install-poki/SKILL.md#what-to-keep-running).

**¿Sirve una cuenta de Apple gratuita? ¿Qué significa el límite de 7 días?** Sirve, pero Apple solo firma sus apps durante 7 días. Con Poki Setup abierto, el ordenador despierto y el iPhone accesible, comprueba cada 6 horas si quedan 2 días o menos y renueva la firma. Sin renovación, la app deja de abrirse al caducar; Poki te avisa durante los últimos 2 días. Consulta [sin cuenta de desarrollador de pago](../skills/install-poki/SKILL.md#no-paid-developer-account).

**¿Qué iPhone y versión de iOS necesito?** iOS 18 o posterior en un iPhone XS, XR, SE (2.ª generación) o posterior. También se instala en iPad con iPadOS 18 o posterior. Las pruebas físicas se han hecho en iOS 27; iOS 18 a 26 usan otro método de control que aún no se ha verificado en un iPhone físico. Consulta [verificación y límites conocidos](verification.md).

**¿Necesito mi propia cuenta del modelo?** Sí. Inicia sesión con ChatGPT Plus o Pro, introduce una clave API de Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter u OpenCode Go, o usa tu servidor compatible con OpenAI. Las conversaciones por voz también requieren una clave de modelo de voz. Consulta [Qué necesitas](#qué-necesitas).

**¿Qué hago si no aparecen actualizaciones, por ejemplo en una red de China continental?** Poki consulta GitHub. Algunas redes no pueden acceder o alcanzan los límites 403 y 429. Prueba otra red o servidor proxy, o usa Renew en Poki Setup desde el ordenador. Consulta [Actualizar Poki](#actualizar-poki).

**¿Poki cambia cosas en mi iPhone? ¿Pide permiso antes?** Ejecuta tus peticiones en apps reales, incluido el envío de mensajes, y envía el contenido de la pantalla al servicio de modelos configurado. Los pagos, las eliminaciones y las acciones en Wallet siempre requieren confirmación. Para otros pasos sensibles, como enviar mensajes o escribir contraseñas, eliges en `Settings > Approvals` cómo pregunta o si debe preguntar. Consulta los [Problemas conocidos](#problemas-conocidos).

## Actualizar Poki

- **En el iPhone.** Abre la página de firma y actualizaciones de Poki: `Settings > Signing & Updates` en las versiones actuales. Las versiones anteriores pueden situarla dentro de Conexión. Si hay una compilación nueva, podrás descargarla e instalarla. Si pide iniciar sesión, la instalación se hizo desde un ordenador y el iPhone aún no tiene tu cuenta de Apple. Usa la cuenta con la que instalaste Poki o actualiza desde el ordenador.
- **Desde el ordenador.** Renew en Poki Setup instala la compilación más reciente del canal elegido sobre la app existente. En Mac también puedes pedir al agente "Actualiza Poki en mi iPhone". La habilidad install-poki tiene un proceso de actualización que comprueba primero la versión instalada y la identidad de firma.
- Si la actualización se detiene en "Finishing the update", cierra Poki desde el selector de apps, ábrelo y comprueba la versión en Ajustes. Si no ha cambiado, actualiza con Poki Setup desde el ordenador. No borres Poki para arreglar una actualización: también se borrarían las conversaciones.

Consulta los [canales de publicación](release-channels.md) para conocer cómo pasa una compilación de Alpha a Beta.

## Prueba una tarea

Abre Poki y escribe una tarea en el campo de mensaje, como "Consulta el tiempo de mañana y dime si necesito paraguas", o toca una app de la pantalla de inicio para iniciar una tarea en ella. Poki trabaja en la app que aparece en pantalla, muestra cada paso en la Dynamic Island y la pantalla bloqueada, y pide permiso según tus ajustes.

También puedes llamarlo sin abrirlo: mantén pulsado el botón de Acción para hablar con él, o usa Talk to Poki y Send Task to Poki desde Atajos y Siri. Las tareas enviadas así responden mediante una notificación. En iPhone Duo en Vista dividida, Poki puede trabajar en dos apps a la vez.

> **Nota:** Poki controla tu iPhone real. Si le pides que envíe mensajes o haga pagos, lo hará.

## Problemas conocidos

- Poki maneja tu iPhone real y ejecuta los mensajes o pagos que le pidas. El contenido de la pantalla se envía al servicio de modelos configurado.
- Si no puedes iniciar sesión con tu cuenta de Apple en el iPhone, renueva y actualiza desde Poki Setup en el ordenador.
- El soporte físico solo se ha verificado en iPhones con interfaz en chino y orientación vertical. No se admite la orientación horizontal.
- Esta versión no se ha probado en un iPhone físico anterior a iOS 27 ni en un iPad. En iPhones antiguos o pequeños, el oso tridimensional y las animaciones de inicio pueden generar más calor o ir más lentos. El modo de bajo consumo y Reducir movimiento muestran una imagen fija del oso.
- La firma de una cuenta de Apple gratuita dura 7 días. Mantén el iPhone accesible desde Poki Setup o renueva manualmente antes de que caduque.
- Las consultas de versiones a GitHub pueden fallar con 403 o 429, normalmente por compartir una red con otras personas. Cambia de red o servidor proxy, o espera una hora.

Consulta más límites y resultados en [verificación y límites conocidos](verification.md).

## Hoja de ruta

Son líneas de trabajo, no fechas. Las funciones publicadas figuran en [CHANGELOG.md](../CHANGELOG.md).

**Publicado en 0.4 Beta**

- La app de iPhone ejecuta tareas sin ordenador tras configurarla, con aprobaciones en la pantalla bloqueada y la Dynamic Island.
- Instalación con tu agente o Poki Setup desde Mac o Windows, con una cuenta de Apple gratuita.
- Control nativo en iOS 27 y posteriores, y tareas web en el navegador integrado de Poki.
- Una pantalla de inicio con el oso tridimensional, conversaciones por voz, el botón de Acción, conversaciones archivadas, iPhone Duo en Vista dividida, tamaño de interfaz ajustable y modo oscuro.

**En curso**

- Una fuente de descarga más fiable para las actualizaciones, con gestión unificada.
- La interfaz en más idiomas.

**Previsto**

- Verificar más iPhones, versiones de iOS e idiomas de pantalla en dispositivos físicos.
- Más proveedores de modelos.

## Otras herramientas

[Poki MCP](poki-mcp.md) conecta el agente de un ordenador a un iPhone o al simulador de iOS; esta herramienta anterior ya no se actualiza.

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent) es el agente de terminal con canales de iMessage y Telegram. La guía enlazada conserva las instrucciones de instalación y uso.

## Descargo de responsabilidad

Poki es un proyecto independiente de código abierto. No está afiliado a Apple, OpenAI ni a los creadores de ninguna app o sitio web que opere, ni cuenta con su respaldo. iPhone es una marca comercial de Apple Inc.

Automatizar apps y sitios web de terceros puede infringir sus condiciones de servicio. Decide por tu cuenta si usas Poki con un servicio determinado. Eres responsable de lo que haga en tu dispositivo y tus cuentas, incluidos los mensajes que envíe, los cambios que realice y cualquier restricción de cuenta que se derive de ello.

Poki se proporciona "tal cual", sin garantía, según lo establecido en la licencia AGPL-3.0.

## Licencia

El código de Poki es código abierto bajo la [licencia AGPL-3.0-only](../LICENSE).

El oso de Poki, el icono de la app y el resto de las ilustraciones de Poki no están cubiertos por esa licencia. Puedes usar capturas de pantalla para hablar de Poki; un fork necesita su propio nombre y sus propias ilustraciones. Consulta [BRAND.md](../BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. Las dependencias de código abierto y los recursos de terceros conservan sus respectivas licencias; consulta [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Para contribuir, consulta [CONTRIBUTING.md](../CONTRIBUTING.md).
