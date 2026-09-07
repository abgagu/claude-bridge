# claude-bridge

Marketplace personal con un único plugin, `bridge`: hub de mensajería por ficheros entre sesiones de
Claude Code de proyectos distintos **de la misma máquina**. Cada sesión tiene una bandeja en
`~/.claude/bridge/inbox/<id>/`; un monitor la despierta cuando entra un mensaje; la skill
`bridge:bridge-watch` lo procesa y contesta. Protocolo completo: `plugins/bridge/skills/bridge-watch/BRIDGE.md`.

## Qué contiene el plugin

```
plugins/bridge/
  .claude-plugin/plugin.json      manifiesto (la version manda: sin bump no hay update)
  monitors/monitors.json          monitor "always": monta el vigilante de bandeja al arrancar la sesion
  skills/bridge-watch/SKILL.md    la skill (procesar bandeja, encargar, despertar al coordinador)
  skills/bridge-watch/BRIDGE.md   el protocolo (referencia de la skill)
  skills/bridge-init/SKILL.md     alta asistida de un proyecto
  scripts/bridge-monitor.ps1      vigilante parametrizado (identidad por marcador o roster, auto-gate inactivo, mutex)
  scripts/bridge-monitor.sh       variante POSIX (inotify, con sondeo de respaldo)
  scripts/bridge-open-peer.ps1    abre una sesion LIMPIA de un peer (limpia entorno heredado, NO_COLOR=1)
  templates/ultracode.settings.json
```

Lo que **no** contiene, porque es estado de cada máquina y lo crea `bridge:bridge-init`:
`~/.claude/bridge/participants.json`, `inbox/`, `archive/`, `tmp/`.

## Instalación

Solo por `git` (RemoteSigned ejecuta `.ps1` clonados; un zip descargado llevaría mark-of-the-web y
no correría sin `Unblock-File`). Ámbito **usuario**: los monitores de plugin no cargan en ámbito proyecto.

```
claude plugin marketplace add abgagu/claude-bridge
claude plugin install bridge@claude-bridge --scope user
```

Para probar desde un checkout local antes de publicar:

```
claude plugin marketplace add C:/workspace/claude-bridge
claude plugin install bridge@claude-bridge --scope user
```

Validación del paquete: `claude plugin validate C:/workspace/claude-bridge` y
`claude plugin validate C:/workspace/claude-bridge/plugins/bridge`.

Después, en cada proyecto que vaya a participar: `/bridge:bridge-init` y reiniciar la sesión.

Requisitos: Claude Code >= 2.1.196 (sustitución de `${CLAUDE_PROJECT_DIR}` en skills); Windows con
PowerShell y Windows Terminal para el camino de despertar peers (`wt`, ventana `bridge-peers`). En
POSIX funcionan envío, recepción y monitor, pero no hay lanzador.

## Test aislado antes de dar por bueno el monitor (obligatorio la primera vez)

1. Proyecto participante, plugin instalado, **sin** ningún bloque "monta el monitor" en su CLAUDE.md:
   al arrancar la sesión la interfaz debe mostrar "1 monitor" del plugin `bridge`.
2. Con un `.md` en su bandeja, la notificación `BRIDGE NEW:` debe despertar al modelo en reposo y
   disparar `bridge:bridge-watch`.
3. Proyecto sin marcador ni entrada en el roster: el monitor queda inactivo en silencio (sin
   notificación ni turno del modelo; el proceso sigue vivo hasta el fin de la sesión). Si SALIERA,
   el harness se lo contaría al modelo y costaría un turno en cada arranque de cada proyecto.
4. Segunda sesión sobre el mismo proyecto: `BRIDGE WARN: ... already has a watcher`.
5. `bridge-open-peer.ps1 -Peer <id> -Ultracode`: cabecera con `xhigh effort` y logo gris.

## Migración desde la instalación manual (una máquina que ya tenía el bridge como skill de usuario)

Orden importa: añadir, repuntar, y solo después borrar.

1. Instalar el plugin y pasar el test aislado de arriba.
2. Retirar `~/.claude/skills/bridge-watch` (mientras exista, `/bridge-watch` resuelve a la copia vieja)
   y el bloque del bridge de `~/.claude/AGENTS.md` (la skill ya lleva auto-gate y "encarga primero").
3. Pedir a cada peer que borre de su CLAUDE.md el bloque "montar el monitor al arrancar" (o lo deje en
   una línea: "participa en el bridge con id X; el monitor lo monta el plugin").
4. Borrar por lista explícita las copias antiguas del vigilante (`~/.claude/bridge/bridge-monitor-*.ps1`,
   `~/.claude/bridge/monitors/`, copias dentro de los árboles de los proyectos). Una copia versionada en
   un repositorio es un borrado con commit.
5. Sustituir en los textos "skill `bridge-watch`" por "skill `bridge:bridge-watch`".

## Límites que conviene saber

- **Un bridge por máquina.** Instalar el plugin en otra máquina crea OTRO bridge, no da acceso a este.
- El protocolo fija el id del coordinador en `orchestrator`. Sin un participante con ese id, la
  excepción "cualquier peer puede despertar al coordinador" no aplica.
- Los monitores de plugin son experimentales: solo sesiones interactivas, solo ámbito usuario, y se
  apagan con `disableAllHooks` o deshabilitando el plugin. Un `/reload-plugins` arranca un segundo
  vigilante; el mutex hace que salga con un aviso.
