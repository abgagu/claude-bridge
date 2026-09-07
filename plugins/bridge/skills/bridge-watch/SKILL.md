---
name: bridge-watch
description: >
  Procesa el Bridge: buzón de mensajería por ficheros entre proyectos locales de Claude Code (estado en ~/.claude/bridge/). Determina tu identidad, lee tu bandeja de entrada, procesa/archiva mensajes y encarga tareas a otros proyectos con escritura atómica.
  Trigger: "Arma el bridge", "mira el bridge", "revisa la bandeja", "encárgale al frontend/backend", "dile al otro proyecto", "¿hay algo del otro lado?", o una notificación `BRIDGE NEW:` del monitor de bandeja sobre ~/.claude/bridge/inbox/<tu-id>/.
metadata:
  author: abgagu
  version: "2.0"
allowed-tools: Read, Write, Bash, Glob
---

El **Bridge** es un hub de mensajería por ficheros entre instancias de Claude Code de proyectos
locales distintos. El código vive en este plugin; el estado (roster, bandejas, archivo) vive en
`~/.claude/bridge/` y es **por máquina**: el bridge no cruza máquinas. Cada instancia tiene un
**monitor** sobre su bandeja (`inbox/<tu-id>/`) que la despierta en cuanto aparece un mensaje nuevo;
esta skill se ejecuta ante ese evento o ante un trigger del usuario. Spec canónica completa en
`${CLAUDE_SKILL_DIR}/BRIDGE.md`; roster en `~/.claude/bridge/participants.json`.

**Léete `${CLAUDE_SKILL_DIR}/BRIDGE.md` entero antes de tocar nada del bridge**: lo operativo crítico
está al final.

## Auto-gate (antes de nada)
Si el proyecto no tiene marcador `.claude-bridge-id` ni entrada en `~/.claude/bridge/participants.json`,
**no es participante**: ignora el bridge por completo. Esta skill es común a todos los proyectos de la
máquina; el auto-gate evita que un proyecto ajeno actúe como si fuera del bridge.
Si es participante: **encarga primero** (antes de hacer tu parte) y comprueba que el monitor está
montado (ver "Monitor de bandeja").

## Idioma y economía de tokens (OBLIGATORIO para mensajes internos)
Los mensajes del Bridge son comunicación **máquina-a-máquina** entre instancias de Claude: **escríbelos
en INGLÉS y lo más concisos posible** (`subject` y cuerpo), sin prosa de cortesía ni relleno. Ve al
grano: hechos, rutas, ids, contratos, la acción concreta. Usa abreviaturas/listas en vez de frases
largas. Esto aplica a TODO lo que escribas en `inbox/<destino>/` — encargos nuevos (Paso 4) y respuestas
`ack`/`info`/`question` (Paso 3). El idioma de tu conversación con el USUARIO no cambia; solo el
contenido de los `.md` del Bridge.

## Cuándo usar
- `Arma el bridge` (primer turno de una sesión abierta por el coordinador o el dueño): comprueba el
  monitor, procesa la bandeja del más antiguo al más reciente y no hagas NADA que no salga de un mensaje.
- "mira el bridge" / "revisa la bandeja" / "¿hay algo del otro proyecto?".
- "encárgale al front/back" / "dile al otro proyecto" / "manda esto al otro".
- Una notificación `BRIDGE NEW: <fichero>` del monitor de bandeja.

## Paso 1 — Identidad (SIEMPRE primero)
Determina TU id de proyecto (híbrido, en este orden; el monitor del plugin usa exactamente la misma
resolución):

```bash
# Marcador (principal): la identidad viaja con el proyecto
ID="$(tr -d '[:space:]' < ./.claude-bridge-id 2>/dev/null)"
echo "marcador='${ID}'  cwd='$(pwd)'"
```

- Si el marcador da un id no vacío → ese es tu id.
- Si NO hay marcador → fallback por registro: lee `~/.claude/bridge/participants.json` y compara tu
  `cwd` contra cada `path`. **Normaliza ambos** a minúsculas y separador `/` (en Windows el `cwd`
  puede venir con `\`). Gana la entrada cuyo `path` normalizado sea **prefijo** de tu `cwd`
  normalizado (el prefijo más largo). Esa clave es tu id.

Tu bandeja de entrada es `~/.claude/bridge/inbox/<tu-id>/`. SOLO procesas esa.

## Paso 2 — Auto-gate y alta asistida
Si SÍ tienes id (marcador o match en el registro) → eres participante: ve al Paso 3.

Si NO obtuviste id → este proyecto **aún no está en el Bridge**. NO te auto-registres en silencio.
Si el usuario quiere de verdad usar el Bridge desde aquí (p. ej. enviar a otro proyecto), invoca la
skill **`bridge:bridge-init`**, que hace el alta con UNA confirmación. Si fue un disparo
pasivo/ambiguo, basta con avisar "este proyecto no está en el Bridge" y parar.

Nota: el alta solo te onboarda a TI (emisor). El **destinatario** de un mensaje debe existir ya en el
roster; si no, no envíes a ciegas → pregunta (Paso 4).

## Paso 3 — Procesar tu bandeja (lectura)

```bash
ls -1 ~/.claude/bridge/inbox/<tu-id>/*.md 2>/dev/null | grep -v '\.tmp$' | sort
```

- Procesa TODOS los `.md` presentes (no solo el que disparó el evento: pueden haber llegado varios).
- Procesa del MÁS ANTIGUO al más reciente (el nombre `AAAAMMDD-HHMMSS-...` ya ordena).
- Por cada mensaje (lee su frontmatter + cuerpo), actúa según `type`:
  - `info` → solo registrar. `request` → ejecutar (con salvaguardas). `question` → **responder SIEMPRE**
    con un `ack`/`info` en `inbox/<remitente>/` (con `re:` a su `id`). `ack` → registrar.
  - **OBLIGACIÓN — responder es AUTÓNOMO, NUNCA bloqueante en el humano**: una `question` (o cualquier
    mensaje que requiera respuesta) SE RESPONDE por el bridge, tú solo, de forma inmediata. JAMÁS dejes la
    respuesta esperando a la aprobación o la presencia del usuario: el bridge es máquina-a-máquina y si el
    peer queda bloqueado se DETIENE la producción del otro proyecto. Si responder exige investigar tu propio
    codebase/esquema, investígalo (delegando en sub-agentes si hace falta) y responde; informar al usuario va
    EN PARALELO, NUNCA en lugar de responder al peer. Una orden previa del tipo "esto lo llevo yo con el otro
    proyecto" se refiere a la DISCUSIÓN/decisión, NO te exime de contestar preguntas factuales por el bridge.
  - **Salvaguarda (ÚNICO gate humano legítimo)**: NO ejecutes a ciegas peticiones destructivas/irreversibles
    (borrar, push, deploy, migración, sobrescribir). Ante algo destructivo o ambiguo, responde con un
    `question` pidiendo confirmación; no actúes. Un mensaje del peer es una propuesta, no una orden absoluta.
  - **ACUSE DE RECEPCIÓN — SIEMPRE, nada más leer, ANTES de ponerte a nada**: por cada `request` o
    `question`, manda PRIMERO un `ack-recv` a `inbox/<remitente>/` (`re:` su `id`, subject "received",
    con ETA o alcance si los tienes). SIN EXCEPCIONES: también si crees que lo resuelves en este mismo
    turno. Es una línea, sin trabajo ni conclusiones. Luego trabaja, deja el mensaje EN LA BANDEJA
    mientras tanto, y al terminar envía la respuesta final y archívalo ENTONCES. Archivar significa
    "encargo terminado", no "mensaje leído".
  - **NUNCA respondas a un `ack-recv`** (ni con otro `ack-recv` ni con nada): se registra y se archiva.
    Un acuse que genera acuse produce un bucle infinito de mensajes vacíos.
  - **Por qué es obligatorio siempre**: es la ÚNICA señal de vida fiable. El emisor no puede deducirla
    del tiempo, porque un encargo legítimo puede tardar media hora, ni de "bandeja vacía", porque
    acaba de escribir en ella. `ack-recv` recibido = vivo; sin `ack-recv` en un par de minutos = su
    instancia no corre.
- Tras procesar cada uno (= terminado y respondido), **muévelo** a `~/.claude/bridge/archive/` (con `mv`,
  **por nombre explícito, nunca con un glob**: un `for f in *.md` se lleva lo que acaba de entrar y lo
  archiva sin leer). Nunca lo borres.
- Resume brevemente qué hiciste con cada mensaje.

## Paso 4 — Encargar a otro proyecto (escritura)
1. **Valida el destino**: el `<id-destino>` debe existir en `participants.json`. Si no, NO envíes a
   ciegas → pregunta al usuario.
2. Construye el mensaje (**en INGLÉS y conciso** — ver "Idioma y economía de tokens") con frontmatter YAML + cuerpo:

   ```
   ---
   from: <tu-id>
   to: <id-destino>
   type: info|request|question|ack|ack-recv
   id: AAAAMMDD-HHMMSS-<slug>
   re: <id-respondido>        # opcional
   subject: <texto corto>
   date: <ISO>
   ---
   <cuerpo / instrucción concreta>
   ```

   Nombre del fichero = `<id>.md`, con `<slug>` de 2-4 palabras en kebab-case. Timestamp con
   `date +%Y%m%d-%H%M%S`.
3. **Escritura ATÓMICA (obligatorio)**: escribe primero `…/inbox/<id-destino>/<nombre>.md.tmp` y
   renómbralo a `.md` (`mv`). El lector ignora los `*.tmp`.
4. **NUNCA reescribas un mensaje ya entregado, ni con el mismo id.** Si te equivocas, manda una
   CORRECCIÓN con id NUEVO y `re:` al original. La atomicidad evita que lean un fichero a medias; NO
   evita que ya hayan leído entera la versión anterior, y no puedes saber si lo han hecho. Caso real:
   el receptor leyó y contestó la versión rota, y al archivar guardó la corregida — el archivo dejó de
   coincidir con lo que realmente ejecutó.
5. **Heredoc SIEMPRE entrecomillado** (`<<'EOF'`) al redactar el cuerpo. Sin comillas, los backticks
   del texto se ejecutan como comando y truncan el mensaje sin avisar.
6. **El disparador de la espera es si el mensaje PIDE ALGO, no la etiqueta `type`.** Si esperas que el
   peer haga o cambie algo, es un `request` y esperas su `ack-recv`; un `info` no lleva acuse y nadie
   vigila su recepción.

## Reglas operativas (proactivas)
- **Encarga PRIMERO**: si una tarea necesita a otro proyecto, entrega el encargo ANTES de ponerte con
  tu parte (el bridge vive del paralelismo); nunca lo dejes para el final.
- **Monitor activo al encargar**: tras encargar, comprueba que tu monitor de bandeja está montado
  (ver abajo) para enterarte de la respuesta / de encargos de vuelta.
- **Despertar a un peer parado NO es cosa tuya.** Si necesitas que arranquen la sesión de otro
  proyecto, pídeselo al **coordinador** (`orchestrator`); no lo hagas tú. Si cualquiera puede arrancar
  a cualquiera aparecen tormentas de arranque y proliferación de procesos. El mecanismo está en
  `BRIDGE.md`, sección "Despertar a un peer parado", y está restringido al coordinador y al dueño.
- **Si el COORDINADOR no acusa recibo, DESPIÉRTALO tú.** Es la ÚNICA excepción a la regla anterior:
  cualquier peer puede arrancar la sesión del coordinador, y solo la suya. No hay riesgo de tormenta
  porque es una estrella —un único destino, sin ciclos—, y sin esto la coordinación se para entera
  hasta que aparezca el dueño. Cómo: sección "Despertar al coordinador" de esta skill.
  Criterio: le entregaste algo y no llegó su `ack-recv` en un par de minutos. **Entrega primero,
  despierta después**, nunca al revés. Avisa igualmente a tu dueño: que el coordinador estuviera caído
  es un dato que querrá saber. Y si el trabajo se puede hacer sin él, hazlo en vez de esperar.
  Si en esta máquina no existe un participante `orchestrator`, la excepción no aplica: no hay a quién
  despertar, y la coordinación multi-peer la hace el dueño a mano.

## Monitor de bandeja
**Lo monta el plugin, no tú.** `monitors/monitors.json` declara un monitor `always` que arranca
`${CLAUDE_PLUGIN_ROOT}/scripts/bridge-monitor.ps1` al inicio de cada sesión, con la raíz del proyecto
como `-Project`. El script resuelve tu id igual que el Paso 1, sale en silencio si el proyecto no
participa (auto-gate), y si participa vigila `~/.claude/bridge/inbox/<tu-id>/`: emite una línea
`BRIDGE NEW: <fichero>` por cada `.md` nuevo (barrido inicial al arrancar + watcher + re-barrido cada
5 s como red de seguridad, ignorando `*.tmp`). Cada línea llega a la sesión como notificación y dispara
esta skill. En reposo no emite nada.

- **Comprobación**: la interfaz debe mostrar **"1 monitor"** del plugin `bridge`. Si no aparece, el
  monitor no está montado y NO te enterarás de nada.
- **Un solo vigilante por bandeja**: si ya hay uno (segunda sesión sobre el mismo proyecto, o
  `/reload-plugins` con el anterior vivo), el nuevo emite `BRIDGE WARN: ... already has a watcher` y
  sale. Un `BRIDGE WARN` al arrancar significa que **hay otra sesión sobre este proyecto**: díselo al
  usuario, no lo ignores (dos sesiones procesan los mismos mensajes y responden dos veces).
- `BRIDGE ERROR: inbox for '<id>' not found` = hay marcador pero no bandeja: ejecuta `bridge:bridge-init`.
- Los monitores de plugin solo cargan en sesiones interactivas y con el plugin instalado en ámbito
  **usuario** (`--scope user`); no cargan desde plugins de ámbito proyecto ni con `disableAllHooks`.

### Montaje manual — SOLO si el plugin no lo montó
Si el host no tiene el tool Monitor o el plugin no pudo arrancarlo, móntalo tú UNA vez por sesión con
el tool **Monitor**, `persistent: true`:

	powershell -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-monitor.ps1" -Project "${CLAUDE_PROJECT_DIR}"

(en POSIX: `"${CLAUDE_PLUGIN_ROOT}/scripts/bridge-monitor.sh" -p "${CLAUDE_PROJECT_DIR}"`).

### ERRORES QUE NO DEBES COMETER (aprendidos en producción)
1. **Tiene que ser el tool `Monitor`, NUNCA `Bash` con `run_in_background`.** Ambos ejecutan el script
   y emiten líneas `BRIDGE NEW:`, pero con `run_in_background` esas líneas van a un fichero de salida
   que nadie lee: parece montado y no despierta a nadie. Comprobación: "1 monitor", no "1 shell".
2. **NO uses `-ExecutionPolicy Bypass`.** Un clasificador de permisos lo bloquea y no hace falta: la
   política `RemoteSigned` ya ejecuta scripts locales sin firma; los del plugin llegan por `git` (sin
   mark-of-the-web). Si de verdad estuviera restringida, usa `-ExecutionPolicy RemoteSigned`, nunca `Bypass`.
3. **No montes un segundo vigilante "por si acaso"**: el mutex lo rechazará con un `BRIDGE WARN` y
   solo añadirás ruido. Si dudas de si está montado, mira la interfaz.
4. **Se monta UNA sola vez por sesión.** No lo re-armes tras procesar mensajes; el watcher persistente
   sigue emitiendo. Si el monitor te notifica un fichero que tú mismo creaste para probar, bórralo y no
   lo trates como mensaje.

## Despertar al coordinador (Windows) — el CÓMO
Solo aplica al caso autorizado: el coordinador (`orchestrator`) no acusó recibo en un par de minutos.
Para cualquier otro peer, NO lo hagas: pídeselo a él. La regla y el porqué, en `BRIDGE.md`. El mismo
comando lo usan el coordinador y el dueño para despertar a cualquier peer.

### UNA SOLA VENTANA, `bridge-peers`, con una PESTAÑA por sesión — no una ventana por cada una
Todas las sesiones que abre Claude van a la MISMA ventana nombrada de Windows Terminal:

```powershell
wt -w bridge-peers new-tab --title <peer> --suppressApplicationTitle `
  powershell -NoExit -File "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-open-peer.ps1" -Peer <peer>
```

La primera invocación crea `bridge-peers`; las siguientes añaden pestaña. El nombre propio es lo que
lo hace seguro: **NUNCA `-w 0`**, que no es "mi ventana" sino "la usada más recientemente" — es decir,
normalmente LA CONSOLA DEL HUMANO, a la que le meterías las pestañas dentro. **NUNCA `Start-Process wt`
a pelo**: abre una ventana NUEVA cada vez y siembra el escritorio.

Añade `-Ultracode` solo si el encargo que espera al peer justifica fan-out real (auditoría de su
árbol, barrido, migración con muchos sitios); para leer un mensaje y acusar recibo es desproporcionado.

### Qué se le inyecta al arrancar: SOLO `Arma el bridge`, nunca el contenido de la bandeja
El peer tiene que armarse por el mecanismo del bridge, no porque quien lo lanza le haya pegado el
mensaje en el prompt: si se le pasa el contenido, ya no se sabe si el mecanismo funciona solo.
Metadatos como mucho; el contenido, jamás. `bridge-open-peer.ps1` ya lleva ese prompt por defecto.

### Por qué un lanzador y no `wt` a pelo: el entorno SE HEREDA
Si lanzas `claude` heredando el entorno de otra sesión de Claude, la nueva nace contaminada:
- `CLAUDE_CODE_CHILD_SESSION=1` -> nace como HIJA y **NO GUARDA TRANSCRIPT**. Es lo peor: son justo
  las sesiones que hay que poder auditar.
- `CLAUDE_CODE_MESSAGING_SOCKET` / `..._TOKEN` -> nace apuntando al canal de mensajería de la madre.
- `CLAUDE_CODE_SESSION_ID`, `..._BRIDGE_SESSION_ID`, `..._ENTRYPOINT`, `CLAUDE_PID`, `CLAUDECODE`.

El lanzador limpia esas ocho. **`NO_COLOR` la FIJA a `1`, a propósito**: mantiene la salida libre de
códigos ANSI y hace que el logo salga GRIS, lo que permite distinguir de un vistazo qué sesiones abrió
Claude y cuáles el humano. **El gris es una SEÑAL, no un defecto: no lo "arregles".** `GIT_TERMINAL_PROMPT=0`,
si lo fijas, solo impide que git pida credenciales POR TERMINAL; el credential helper sigue funcionando.

**NADA de `-NoProfile` en la ventana interactiva**: eso es para ejecutar un `.ps1`. En una consola
donde va a trabajar el humano le quita alias, funciones y `PATH`.

### Trampas de `wt`, cada una costó un intento
- **NUNCA un `;` dentro del `-Command`**: `wt` lo parsea como separador de subcomando antes de que
  llegue a PowerShell y parte la pestaña en dos. Por eso el lanzador va en un `.ps1` con `-File`.
- **Sin `--suppressApplicationTitle` los títulos NO sobreviven**: PowerShell y `claude` reescriben el
  título en caliente y se comen el `--title`.
- **`-w 0` NO es "mi ventana"**, es "la usada más recientemente", que suele ser la consola del humano.
- Si la ruta del plugin lleva espacios (nombre de usuario con espacio), las comillas alrededor de
  `-File "..."` son obligatorias.

## Referencias
- Spec canónica del protocolo: `${CLAUDE_SKILL_DIR}/BRIDGE.md`.
- Roster de participantes: `~/.claude/bridge/participants.json`.
- Alta de un proyecto nuevo: skill `bridge:bridge-init`.
- Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/` (`bridge-monitor.ps1`, `bridge-monitor.sh`, `bridge-open-peer.ps1`).
