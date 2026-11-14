<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki usa tu iPhone como lo harías tú</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Animación de la página de inicio del sitio web de Poki">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | Español<br>
  <a href="https://poki.bot">poki.bot</a>
</p>

<!-- badges:start -->
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="License: AGPL-3.0-only"></a>
  <a href="https://github.com/JosssphZhou/poki/stargazers"><img src="https://img.shields.io/github/stars/JosssphZhou/poki" alt="GitHub stars"></a>
  <a href="https://github.com/JosssphZhou/poki/forks"><img src="https://img.shields.io/github/forks/JosssphZhou/poki" alt="GitHub forks"></a>
  <a href="https://github.com/JosssphZhou/poki/issues"><img src="https://img.shields.io/github/issues/JosssphZhou/poki" alt="GitHub issues"></a>
  <a href="https://github.com/JosssphZhou/poki/releases/tag/app-0.4.0-beta.1"><img src="https://img.shields.io/badge/Poki_App-0.4.0_Beta-blue" alt="Poki App 0.4.0 Beta"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="Platform: iOS, macOS and Windows">
</p>
<!-- badges:end -->

Poki es una app que maneja tu iPhone. Lee la pantalla, toca, escribe y desplaza el contenido en apps reales. Tú eliges cómo pide permiso; los pagos, las eliminaciones y las acciones en Wallet siempre requieren confirmación.

**La app Poki** funciona en el propio iPhone. Le pides una tarea en el chat y la realiza en tus otras apps. La instalas una vez desde un Mac o un PC con Windows; después, ejecuta tareas sin el ordenador.

Consulta los cambios de cada versión en [CHANGELOG.md](CHANGELOG.md).

## Instala Poki en tu iPhone

Necesitas un Mac o un PC con Windows para la instalación inicial.

- **En Mac**, pide a tu agente que instale Poki o descarga Poki Setup para macOS y sigue las instrucciones de la ventana.
- **En Windows**, descarga Poki Setup para Windows y sigue sus instrucciones. Instala antes Apple Devices o iTunes para que el PC detecte el iPhone por USB. Tu agente también puede usar la herramienta de línea de comandos de Poki Setup.
- **Después**, Poki ejecuta tareas en el iPhone sin el ordenador. Con una cuenta de Apple gratuita, la firma dura 7 días y Poki Setup puede renovarla mientras siga abierto en el ordenador. Consulta las [preguntas frecuentes](#preguntas-frecuentes).

### Con tu agente (recomendado)

Dile a tu agente, por ejemplo Claude Code o Codex:

```text
Instala Poki en mi iPhone desde https://github.com/JosssphZhou/poki
```

El agente sigue la [habilidad install-poki](skills/install-poki/SKILL.md) y ejecuta `bin/install-iphone.mjs`, que automatiza los pasos posibles. Tú completas lo que iOS exige en persona: introducir tu cuenta de Apple en la ventana de Poki Setup del Mac, tocar Confiar en el iPhone, activar el modo de desarrollador, confiar en el desarrollador y abrir Poki. En el primer inicio, Poki pide activar el modo de automatización. Toca Continuar e introduce el código del iPhone. Si cancelas, vuelve a activar Poki para que lo pregunte de nuevo. El agente te indica qué hacer en cada paso. Una cuenta de Apple gratuita sirve.

El instalador usa el canal Alpha, salvo que pidas otro, como Beta. Cada compilación llega primero a Alpha y pasa a Beta tras más pruebas.

¿No tienes Node.js 24 o usas Windows? La misma petición funciona después de instalar Poki Setup; el agente usa su herramienta de línea de comandos. También puedes copiar la petición desde su menú: Poki > Copy Prompt for Your Agent en Mac, o Settings > Use an agent en Windows.

Si GitHub devuelve 403 o 429 al consultar las versiones, suele haberse agotado el límite horario de peticiones anónimas compartido por tu red. Prueba otra red o servidor proxy, o espera una hora.

### Con Poki Setup

Si prefieres hacerlo tú, descarga Poki Setup para macOS (`.dmg`) o Windows (`.exe`, aportado por [ZhehanZhang](https://github.com/ZhehanZhang)) desde la [versión Alpha](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest) y sigue las instrucciones. La versión Beta incluye los mismos archivos de Poki Setup. Hasta que elijas un canal en sus ajustes, instala la versión Stable más reciente, o Beta si todavía no hay Stable. Consulta los pasos en [Poki Setup](desktop/README.md).

### Qué necesitas

| Elemento | Requisito |
| --- | --- |
| iPhone | iOS 18 o posterior: iPhone XS, XR, SE (2.ª generación) o posterior. Las pruebas físicas se han realizado con iPhones en iOS 27. |
| Ordenador | Un Mac con macOS 14 o posterior, o un PC con Windows (x64) y Apple Devices o iTunes. La instalación mediante el script del agente en Mac también necesita Node.js 24 o posterior. |
| Cable y cuenta | Un cable USB de datos y una cuenta de Apple. Con una cuenta gratuita, la firma dura 7 días y Poki Setup puede renovarla. |
| Conexión | Una app VPN en el iPhone que dirija 10.7.0.1 al propio teléfono. Sirven LocalDevVPN, gratuita en el App Store, o Karing y Shadowrocket configuradas con las instrucciones de Poki. |
| Cuenta del modelo | Necesitas la tuya. Puedes empezar con ChatGPT Plus o Pro, introducir una clave API de Anthropic, OpenAI, Gemini, DeepSeek u OpenRouter, o usar tu propio servidor compatible con OpenAI. La suscripción de Claude no permite iniciar sesión aquí; usa una clave API de Anthropic. |

En iOS 27 y posteriores, Poki controla el iPhone mediante servicios nativos. En iOS 18 a 26 usa una sesión XCTest, que necesita la automatización de la interfaz activada en los ajustes de desarrollador del iPhone. La app también se instala en iPad con iPadOS 18 o posterior.

### Preguntas frecuentes

**¿Puedo instalar Poki desde Windows?** Sí. Poki Setup para Windows instala, empareja y renueva Poki como la versión para Mac. Instala primero Apple Devices o iTunes para que el PC detecte el iPhone. Consulta [Poki Setup](desktop/README.md).

**¿Sigo necesitando el ordenador después de instalarlo?** Para ejecutar tareas, no. Poki funciona en el iPhone. Con una cuenta gratuita, mantén Poki Setup abierto en el ordenador para renovar la firma, o inicia sesión en Poki con tu cuenta de Apple para que el iPhone la renueve. Si no puedes iniciar sesión, usa Poki Setup en el ordenador. Consulta [qué mantener en ejecución](skills/install-poki/SKILL.md#what-to-keep-running).

**¿Sirve una cuenta de Apple gratuita? ¿Qué significa el límite de 7 días?** Sirve, pero Apple solo firma sus apps durante 7 días. Con Poki Setup abierto, el ordenador despierto y el iPhone accesible, comprueba cada 6 horas si quedan 2 días o menos y renueva la firma. Sin renovación, la app deja de abrirse al caducar; Poki te avisa durante los últimos 2 días. Consulta [sin cuenta de desarrollador de pago](skills/install-poki/SKILL.md#no-paid-developer-account).

**¿Qué iPhone y versión de iOS necesito?** iOS 18 o posterior en un iPhone XS, XR, SE (2.ª generación) o posterior. También se instala en iPad con iPadOS 18 o posterior. Las pruebas físicas se han hecho en iOS 27; iOS 18 a 26 usan otro método de control que aún no se ha verificado en un iPhone físico. Consulta [verificación y límites conocidos](docs/verification.md).

**¿Necesito mi propia cuenta del modelo?** Sí. Inicia sesión con ChatGPT Plus o Pro, introduce una clave API de Anthropic, OpenAI, Gemini, DeepSeek u OpenRouter, o usa tu servidor compatible con OpenAI. Las conversaciones por voz también requieren una clave de modelo de voz. Consulta [qué necesitas](#qué-necesitas).

**¿Qué hago si no aparecen actualizaciones, por ejemplo en una red de China continental?** Poki consulta GitHub. Algunas redes no pueden acceder o alcanzan los límites 403 y 429. Prueba otra red o servidor proxy, o usa Renew en Poki Setup desde el ordenador. Consulta [actualizar Poki](#actualizar-poki).

**¿Poki cambia cosas en mi iPhone? ¿Pide permiso antes?** Ejecuta tus peticiones en apps reales, incluido el envío de mensajes, y envía el contenido de la pantalla al servicio de modelos configurado. Los pagos, las eliminaciones y las acciones en Wallet siempre requieren confirmación. Para otros pasos sensibles, como enviar mensajes o escribir contraseñas, eliges en Ajustes > Aprobaciones cómo pregunta o si debe preguntar. Consulta los [problemas conocidos](#problemas-conocidos).

## Actualizar Poki

- **En el iPhone.** En 0.4.0, abre Ajustes > Conexión > Firma y actualizaciones. Si hay una compilación nueva, podrás descargarla e instalarla. Si pide iniciar sesión, la instalación se hizo desde un ordenador y el iPhone aún no tiene tu cuenta de Apple. Usa la cuenta con la que instalaste Poki o actualiza desde el ordenador.
- **Desde el ordenador.** Renew en Poki Setup instala la compilación más reciente del canal elegido sobre la app existente. En Mac también puedes pedir al agente «Actualiza Poki en mi iPhone». La habilidad install-poki tiene un proceso de actualización que comprueba primero la versión instalada y la identidad de firma.
- Si la actualización se detiene en «Finishing the update», cierra Poki desde el selector de apps, ábrelo y comprueba la versión en Ajustes. Si no ha cambiado, actualiza con Poki Setup desde el ordenador. No borres Poki para arreglar una actualización: también se borrarían las conversaciones.

Consulta los [canales de publicación](docs/release-channels.md) para conocer cómo pasa una compilación de Alpha a Beta.

## Problemas conocidos

- Poki maneja tu iPhone real y ejecuta los mensajes o pagos que le pidas. El contenido de la pantalla se envía al servicio de modelos configurado.
- Si no puedes iniciar sesión con tu cuenta de Apple en el iPhone, renueva y actualiza desde Poki Setup en el ordenador.
- El soporte físico solo se ha verificado en iPhones con interfaz en chino y orientación vertical. No se admite la orientación horizontal.
- Esta versión no se ha probado en un iPhone físico anterior a iOS 27 ni en un iPad. En iPhones antiguos o pequeños, el oso tridimensional y las animaciones de inicio pueden generar más calor o ir más lentos. El modo de bajo consumo y Reducir movimiento muestran una imagen fija del oso.
- La firma de una cuenta de Apple gratuita dura 7 días. Mantén el iPhone accesible desde Poki Setup o renueva manualmente antes de que caduque.
- Las consultas de versiones a GitHub pueden fallar con 403 o 429, normalmente por compartir una red con otras personas. Cambia de red o servidor proxy, o espera una hora.

Consulta más límites y resultados en [verificación y límites conocidos](docs/verification.md).

## Prueba una tarea

Abre Poki y escribe una tarea, como «Consulta el tiempo de mañana y dime si necesito paraguas», o toca una app de la pantalla de inicio. Poki trabaja en la app que aparece en pantalla, muestra cada paso en la Dynamic Island y la pantalla bloqueada, y pide permiso según tus ajustes.

También puedes llamarlo sin abrirlo: mantén pulsado el botón de acción para hablar, o usa Talk to Poki y Send Task to Poki desde Atajos y Siri. Las tareas enviadas así responden mediante una notificación.

> **Nota:** Poki controla tu iPhone real. Si le pides que envíe mensajes o haga pagos, lo hará.

## Hoja de ruta

Son líneas de trabajo, no fechas. Las funciones publicadas figuran en [CHANGELOG.md](CHANGELOG.md).

**Publicado en 0.4.0 Beta**

- La app de iPhone ejecuta tareas sin ordenador tras configurarla, con aprobaciones en la pantalla bloqueada y la Dynamic Island.
- Instalación con tu agente o Poki Setup desde Mac o Windows, con una cuenta de Apple gratuita.
- Control nativo en iOS 27 y posteriores, y tareas web en el navegador integrado de Poki.
- Nueva pantalla de inicio con el oso tridimensional, conversaciones por voz, botón de acción, conversaciones archivadas y modo oscuro.

**En curso**

- Una fuente de descarga más fiable para las actualizaciones, con GitHub como respaldo.
- Un único canal de actualización en lugar de varios.
- La interfaz en más idiomas.

**Previsto**

- Verificar más iPhones, versiones de iOS e idiomas de pantalla en dispositivos físicos.
- Más proveedores de modelos.

## Documentación

| Tema | Documento |
| --- | --- |
| Cambios de cada versión | [CHANGELOG.md](CHANGELOG.md) |
| Instalar la app de iPhone con un agente | [Habilidad install-poki](skills/install-poki/SKILL.md) |
| Poki Setup para Mac y Windows | [Poki Setup](desktop/README.md) |
| Canales de publicación y promoción de versiones | [Canales de publicación](docs/release-channels.md) |
| Resultados de pruebas, límites y avisos | [Verificación](docs/verification.md) |
| Hoja de ruta | [Hoja de ruta](#hoja-de-ruta) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## Colaboradores principales

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />Abrió el primer issue de Poki, <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>, en iOS 18.6.2: las capturas funcionaban, la accesibilidad y el toque no, y la separación clara lo hizo fácil de seguir.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=240" width="120" height="120" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a><br />El gran cocreador de Poki.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br />Hizo que Poki funcionara en un router en <a href="https://github.com/JosssphZhou/poki/pull/14">#14</a>, de modo que Telegram controla el iPhone con el Mac apagado; siguieron <a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>, <a href="https://github.com/JosssphZhou/poki/pull/17">#17</a> y <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a>.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br />Informó en <a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> de que usbmuxd no listaba ningún iPhone en macOS 27.2; ahora Poki lo dice con claridad y explica por qué un ayudante se detiene antes de tiempo (<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br />Descubrió en <a href="https://github.com/JosssphZhou/poki/issues/10">#10</a> por qué los toques en un iPhone físico eran lentos; la corrección posterior los hizo alrededor de un tercio más rápidos.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br />Portó Poki a Linux y lo probó en un iPhone físico por USB, LAN y Tailscale en <a href="https://github.com/JosssphZhou/poki/issues/16">#16</a>; el README ahora lo enlaza.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br />Rastreó en <a href="https://github.com/JosssphZhou/poki/issues/18">#18</a> los toques fallidos de un iPhone físico hasta la falta de display service; ahora Poki indica que no se envió nada y apunta a prepare-device.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />Corrigió una ruta en caché corrupta que abortaba tareas del Agent sin relación (<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>, <a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>) y después hizo que el Agent reutilice la pantalla ya leída tras cada acción (<a href="https://github.com/JosssphZhou/poki/pull/37">#37</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br />Reportó en <a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> que una petición de detener en lenguaje natural no interrumpía una tarea de iMessage; ahora Poki responde a los mensajes enviados durante la tarea y señala /stop.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br />Reprodujo dos errores del Agent en <a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> y <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a> y luego fusionó siete correcciones y arreglos de pruebas, desde bloqueos de entrada cancelados (<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>) hasta coordenadas táctiles no válidas (<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />Corrigió en <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> una conexión RemotePairing que fallaba al cambiar la dirección LAN del iPhone (<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>); un iPhone real se reconectó en 768 ms.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br />Probó la app de iPhone con datos móviles y desde Windows en <a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> y <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a>, lo que dio lugar a la nota sobre Wi-Fi en la primera configuración (<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>); también informó de <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />Corrigió en <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a> los toques que fallaban siempre por RemotePairing desde un host Windows; después, 5 de 5 toques funcionaron.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br />Hizo en <a href="https://github.com/JosssphZhou/poki/issues/42">#42</a> una comprobación de condiciones de seguros en un iPhone real por Tailscale; su informe orientó errores USB más claros y un cambio de transporte por sesión.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />Grabó vídeos de demostración de Poki controlando un iPhone real, para que los visitantes nuevos vean qué hace antes de instalar nada.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br />Añadió OpenCode Go como cuenta de modelo en la app de iPhone en <a href="https://github.com/JosssphZhou/poki/pull/68">#68</a>, con su propia credencial en el llavero y una elección de modelo independiente.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br />Aportó en <a href="https://github.com/JosssphZhou/poki/issues/69">#69</a> la cronología completa de un fallo de emparejamiento del Runner tras 25 minutos de inactividad; Setup ahora remite a Loopback y Pairing (<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />Hizo que las llamadas por lotes avisen de un dispositivo ambiguo en vez de fallar (<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>) y añadió POKI_MCP_DEVICE (<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>) y una aprobación opcional por tarea (<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />Corrigió que la configuración del emparejamiento llevara a la página de Ajustes equivocada; los pasos de Modo desarrollador y automatización de UI ahora abren la correcta (<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br />Corrigió en <a href="https://github.com/JosssphZhou/poki/pull/139">#139</a> las lecturas de pantalla que superaban el plazo de la llamada, con una prueba de regresión para respuestas del Runner constantemente lentas.</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## Colaboradores especiales

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />Aportó un conjunto completo de diseños para la renovación de 0.4.0, incluidos el chat, las actividades en directo, los ajustes y el primer inicio (<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a>, <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>); ayudaron a definir la nueva interfaz.</td>
    </tr>
  </tbody>
</table>

## Menciones especiales

Gracias a todas las personas que han abierto un issue o un pull request; sus reportes y correcciones hacen que Poki sea cada vez mejor.

<!-- THANKS-WALL:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=160" width="80" height="80" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=160" width="80" height="80" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=160" width="80" height="80" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=160" width="80" height="80" alt="edge369"/><br /><sub><b>edge369</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=160" width="80" height="80" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=160" width="80" height="80" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=160" width="80" height="80" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=160" width="80" height="80" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/htx996"><img src="https://avatars.githubusercontent.com/u/95217139?v=4&size=160" width="80" height="80" alt="htx996"/><br /><sub><b>htx996</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=160" width="80" height="80" alt="igc110"/><br /><sub><b>igc110</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/iTry"><img src="https://avatars.githubusercontent.com/u/1381960?v=4&size=160" width="80" height="80" alt="iTry"/><br /><sub><b>iTry</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=160" width="80" height="80" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kilingzhang"><img src="https://avatars.githubusercontent.com/u/17439300?v=4&size=160" width="80" height="80" alt="kilingzhang"/><br /><sub><b>kilingzhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=160" width="80" height="80" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/lunar-me"><img src="https://avatars.githubusercontent.com/u/275556969?v=4&size=160" width="80" height="80" alt="lunar-me"/><br /><sub><b>lunar-me</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=160" width="80" height="80" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=160" width="80" height="80" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/oasis979559-alt"><img src="https://avatars.githubusercontent.com/u/295108220?v=4&size=160" width="80" height="80" alt="oasis979559-alt"/><br /><sub><b>oasis979559-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=160" width="80" height="80" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=160" width="80" height="80" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=160" width="80" height="80" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=160" width="80" height="80" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=160" width="80" height="80" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/wanghao-SunSky"><img src="https://avatars.githubusercontent.com/u/73684879?v=4&size=160" width="80" height="80" alt="wanghao-SunSky"/><br /><sub><b>wanghao-SunSky</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/windywendyday"><img src="https://avatars.githubusercontent.com/u/65647922?v=4&size=160" width="80" height="80" alt="windywendyday"/><br /><sub><b>windywendyday</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=160" width="80" height="80" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=160" width="80" height="80" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zcyoung2000"><img src="https://avatars.githubusercontent.com/u/62181891?v=4&size=160" width="80" height="80" alt="zcyoung2000"/><br /><sub><b>zcyoung2000</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=160" width="80" height="80" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zqy5608"><img src="https://avatars.githubusercontent.com/u/14949471?v=4&size=160" width="80" height="80" alt="zqy5608"/><br /><sub><b>zqy5608</b></sub></a></td>
    </tr>
  </tbody>
</table>
<!-- THANKS-WALL:END -->

## Otras herramientas

[Poki MCP](docs/poki-mcp.md) conecta el agente de un ordenador a un iPhone o al simulador de iOS; esta herramienta anterior ya no se actualiza.

[Poki Agent](docs/poki-mcp.md#try-a-task-with-poki-agent) es el agente de terminal con canales de iMessage y Telegram. La guía enlazada conserva las instrucciones de instalación y uso.

## Descargo de responsabilidad

Poki es un proyecto independiente de código abierto. No está afiliado a Apple, OpenAI ni a los creadores de ninguna app o sitio web que opere, ni cuenta con su respaldo. iPhone es una marca comercial de Apple Inc.

Automatizar apps y sitios web de terceros puede infringir sus condiciones de servicio. Decide por tu cuenta si usas Poki con un servicio determinado. Eres responsable de lo que haga en tu dispositivo y tus cuentas, incluidos los mensajes que envíe, los cambios que realice y cualquier restricción de cuenta que se derive de ello.

Poki se proporciona «tal cual», sin garantía, según lo establecido en la licencia AGPL-3.0.

## Licencia

El código de Poki es código abierto bajo la [licencia AGPL-3.0-only](LICENSE).

El oso de Poki, el icono de la app y el resto de las ilustraciones de Poki no están cubiertos por esa licencia. Puedes usar capturas de pantalla para hablar de Poki; un fork necesita su propio nombre y sus propias ilustraciones. Consulta [BRAND.md](BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. Las dependencias de código abierto y los recursos de terceros conservan sus respectivas licencias; consulta [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Para contribuir, consulta [CONTRIBUTING.md](CONTRIBUTING.md).

## Agradecimientos

Consulta los [avisos de terceros](THIRD_PARTY_NOTICES.md) para conocer las dependencias y los recursos de código abierto de Poki.
