---
name: bridge-init
description: >
  Da de alta el proyecto actual en el Bridge (mensajería por ficheros entre sesiones de Claude Code de la misma máquina): crea el estado en ~/.claude/bridge si no existe, añade la entrada al roster, crea la bandeja, deja el marcador .claude-bridge-id y lo excluye de git. Una sola confirmación.
  Trigger: "bridge init", "da de alta este proyecto en el bridge", "añade este proyecto al bridge", o la skill bridge-watch cuando el proyecto no tiene identidad.
metadata:
  author: abgagu
  version: "1.0"
allowed-tools: Read, Write, Bash, Glob
---

Alta asistida de UN proyecto en el Bridge. Protocolo completo en la skill `bridge:bridge-watch`
(`BRIDGE.md`). El estado del bridge es **por máquina** (`~/.claude/bridge/`); este alta no lo
comparte con nadie fuera de ella.

## 0. Comprueba que no está ya dado de alta

```bash
ID="$(tr -d '[:space:]' < ./.claude-bridge-id 2>/dev/null)"; echo "marcador='${ID}' cwd='$(pwd)'"
cat ~/.claude/bridge/participants.json 2>/dev/null
```

Si hay marcador con id no vacío, o una entrada cuyo `path` sea prefijo del `cwd` (normalizando
`\`→`/` y mayúsculas): **ya es participante**. Di cuál es su id y para. No dupliques.

## 1. Propón id y descripción
- **id**: por defecto el nombre de la carpeta del proyecto en kebab-case (minúsculas, espacios/`_` → `-`,
  sin caracteres raros). Ej.: `C:/workspace/APP-Mobile` → `app-mobile`.
- **description**: dedúcela del proyecto (1ª línea/heading de `./CLAUDE.md`, o `name`/`description` de
  `package.json`/`composer.json`). Es lo ÚNICO que ven los demás peers para decidir a quién escribir:
  di qué ES y qué NO ES suyo. Si no hay nada, deja un placeholder a rellenar.
- Si el id ya existe en el roster con OTRO `path`: colisión → propón otro id.

## 2. Confirma con el usuario (UNA pregunta)
"Este proyecto no está en el Bridge. ¿Lo doy de alta como `<id>` (description: «…»)?". Deja que edite
`id`/`description`. Si rechaza → detente; NO actúes como participante.

## 3. Tras confirmar, da el alta
1. **Estado** (idempotente): `mkdir -p ~/.claude/bridge/inbox ~/.claude/bridge/archive ~/.claude/bridge/tmp`.
   Si no existe `~/.claude/bridge/participants.json`, créalo con `{}`.
2. **Roster**: añade `"<id>": { "path": "<cwd con barras />", "description": "<desc>" }` con
   **read-modify-write** (lee el JSON, fusiona, reescribe; escritura atómica `.tmp` → `mv`). No
   reescribas ni borres entradas ajenas.
3. **Bandeja**: `mkdir -p ~/.claude/bridge/inbox/<id>`.
4. **Marcador**: escribe `<cwd>/.claude-bridge-id` con `<id>` (una línea, sin espacios).
5. **Git**: si existe `<cwd>/.git/info/exclude`, añade la línea `.claude-bridge-id` (si no está ya).
   El marcador es local a la máquina; no debe viajar con el repositorio.
6. **Ultracode** (opcional, solo hace falta una vez por máquina): si no existe
   `~/.claude/bridge/ultracode.settings.json`, copia `${CLAUDE_PLUGIN_ROOT}/templates/ultracode.settings.json`
   ahí. El lanzador ya lo busca primero dentro del plugin, así que este paso es solo red de seguridad.

## 4. Verificación (dísela al usuario, no la des por hecha)
- El monitor de bandeja lo monta el plugin **al arrancar la sesión**: esta sesión, que ya estaba
  abierta cuando se creó el marcador, no lo tiene. Toca reiniciar la sesión (o `/reload-plugins`) y
  comprobar que la interfaz muestra **"1 monitor"** del plugin `bridge`.
- Si al reiniciar aparece `BRIDGE ERROR: inbox for '<id>' not found`, el paso 3.3 no se hizo.
- Si aparece `BRIDGE WARN: ... already has a watcher`, hay OTRA sesión abierta sobre este proyecto.
- Requisitos del monitor: sesión interactiva y plugin instalado con `--scope user`.

## 5. Avisa de lo que el alta NO hace
- No da de alta a nadie más: el **destinatario** de un mensaje tiene que existir ya en el roster.
- No crea coordinador. Si en esta máquina no hay un participante `orchestrator`, la excepción "cualquier
  peer puede despertar al coordinador" no aplica y la coordinación multi-peer la lleva el dueño a mano.
  Para tener coordinador, da de alta con este mismo procedimiento un proyecto dedicado con id
  `orchestrator`.
- El camino de "despertar a un peer" (`bridge-open-peer.ps1`, ventana `bridge-peers`) es solo Windows
  con Windows Terminal. En POSIX hay envío, recepción y monitor, pero no lanzador.
