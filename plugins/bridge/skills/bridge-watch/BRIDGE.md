# BRIDGE — Hub de mensajería entre proyectos locales (Claude Code)

Buzón de ficheros para que instancias de Claude Code que corren en proyectos locales DISTINTOS se
dejen encargos. NO hay servidor central: cada instancia monta un **monitor** sobre su propia bandeja
y reacciona en cuanto el sistema de ficheros le notifica un mensaje nuevo (event-driven, sin sondeo
periódico). Es un **hub genérico**: cualquier número de proyectos puede participar, sin roles fijos.

## Estructura

```
~/.claude/bridge/            (= C:/Users/<usuario>/.claude/bridge/)  ESTADO, por máquina
  participants.json  <- roster de participantes: id -> { path, description }
  inbox/<id>/        <- bandeja de cada proyecto: su dueño LEE aquí; los demás ESCRIBEN aquí
  archive/           <- mensajes ya procesados (los mueve el receptor; nunca se borran)
  tmp/               <- locks del vigilante (POSIX)
```

El CÓDIGO (este protocolo, la skill `bridge:bridge-watch`, la skill de alta `bridge:bridge-init`, el
vigilante de bandeja y el lanzador de peers) vive en el plugin `bridge` y se actualiza con él. El
estado no se distribuye: lo crea `bridge:bridge-init` en cada máquina. **El bridge no cruza
máquinas**: instalar el plugin en otra máquina crea OTRO bridge.

## Identidad — quién eres (híbrido)

Determina TU id de proyecto, en este orden:

1. **Marcador**: lee `<raíz-del-proyecto>/.claude-bridge-id` (normalmente tu `cwd`). Su contenido
   (1 línea) es tu id. Es la fuente principal: la identidad viaja con el proyecto aunque lo muevas.
2. **Fallback (registro)**: si no hay marcador, busca en `participants.json` la entrada cuyo `path`
   sea prefijo de tu `cwd` (normaliza `/` vs `\` y mayúsculas; gana el prefijo más largo).
3. **Auto-gate**: si no encuentras NI marcador NI entrada en el registro, NO eres participante del
   bridge -> ignora este protocolo. (El plugin y su skill son comunes a todos los proyectos de la
   máquina; esto evita que un proyecto ajeno actúe como si fuera del bridge. El vigilante del plugin
   aplica el mismo auto-gate: sin identidad, queda inactivo en silencio.)

Tu **bandeja de entrada** es `inbox/<tu-id>/`: SOLO procesas esa. En `inbox/<otro>/` solo escribes
mensajes nuevos; nunca borras ni editas los de otros.

## Discovery — a quién puedes escribir

`participants.json` es el roster. Antes de escribir a `X`, comprueba que `X` existe ahí. Si el
destinatario no está en el registro, NO envíes a ciegas: pregunta al usuario.

## Encarga PRIMERO (paralelismo)

El sentido del bridge es que las instancias trabajen EN PARALELO. Por eso, cuando una tarea necesita
a otro proyecto, lo PRIMERO que haces es entregar el encargo en `inbox/<destino>/`; solo DESPUÉS te
pones con TU parte. Nunca termines tu trabajo y mandes el encargo al final: eso lo serializa y vacía
de sentido el bridge. En cuanto detectes que la tarea requiere al peer, redacta y entrega el `.md`
(escritura atómica) como PRIMER paso, y solo entonces implementa lo tuyo.

## Monitor de bandeja (event-driven, reemplaza al sondeo)

El bridge NO usa un `/loop` que despierte a la instancia cada X tiempo. En su lugar, cada instancia
monta UNA vez por sesión un **monitor** sobre `inbox/<tu-id>/`: un proceso que bloquea a nivel de SO
y emite un evento únicamente cuando aparece un `.md` nuevo. Ese evento despierta a la instancia para
procesar el mensaje; en reposo no consume nada y no hay "ticks vacíos".

- **Lo monta el plugin `bridge` al arrancar la sesión** (requisitos en «Arrancar el monitor —
  REQUISITO»; el cómo y el montaje manual de respaldo, en la skill `bridge:bridge-watch`). Queda
  escuchando toda la sesión; tras procesar un mensaje NO hay que re-armarlo (sigue vivo y emitirá el
  siguiente evento).
- **Al encargar, comprueba que el monitor está activo** ("1 monitor" en la interfaz; si no lo está,
  móntalo a mano como dice la skill): así te enteras del `ack` cuando el trabajo esté hecho y de si el
  peer te devuelve una `question`/`request`.
- El archivado (`mv` a `archive/`) saca el `.md` de la bandeja sin crear otro, así que no re-dispara
  el monitor. Solo cuentan los `.md` nuevos.

## Formato de mensaje

Un fichero `.md` con frontmatter YAML + cuerpo:

```
---
from: app-backend        # tu id (del registro)
to: app-frontend         # id destino (del registro)
type: request            # info | request | question | ack
id: 20260624-153000-saludo
re:                      # id del mensaje al que respondes (opcional)
subject: Texto corto
date: 2026-06-24T15:30:00
---

Cuerpo del mensaje / la instrucción concreta.
```

### Tipos
- `info`    : solo para tu conocimiento. Regístralo y archívalo. No requiere acción.
- `request` : te pide que hagas algo en TU proyecto. Ejecútalo (con las salvaguardas de abajo).
- `question`: te pregunta algo. Responde con un `ack` (o `info`) en `inbox/<remitente>/`, con `re:` apuntando a su `id`.
- `ack`     : confirmación / respuesta a un mensaje previo. Regístralo y archívalo.
- `ack-recv`: **acuse de RECEPCIÓN**. Solo dice "lo he leído". No lleva trabajo ni conclusiones.
  Es obligatorio (ver abajo) y **NUNCA se responde**.

## Acuse de RECEPCIÓN — obligatorio, SIEMPRE, nada más leer

El archivado marca "encargo TERMINADO", no "mensaje leído". Sin una señal de "leído", el emisor no
puede distinguir "peer caído" de "peer trabajando", y esa distinción NO se deduce del tiempo: hay
encargos que tardan media hora en completarse legítimamente.

**REGLA: nada más leer un `request` o una `question`, y ANTES de ponerte a nada, envía un `ack-recv`
a `inbox/<remitente>/` con `re:` apuntando a su `id`.** Sin excepciones — tampoco si crees que lo vas
a resolver en el mismo turno. Es una línea; su único contenido es "recibido" (añade ETA o alcance si
los tienes). Después trabaja, y al terminar envía la respuesta final (`info`/`ack`) y ARCHIVA entonces
el mensaje original.

**NUNCA respondas a un `ack-recv`.** Ni con otro `ack-recv` ni con nada: se registra y se archiva. Un
acuse que genera acuse produce un bucle infinito de mensajes sin contenido. Los `ack-recv` son el
único tipo que no admite respuesta.

**Lectura del emisor** (criterio de vida, ya sin ambigüedad):
- `ack-recv` recibido = lo ha leído, está vivo. NO lo levantes, por mucho que tarde el trabajo.
- Sin `ack-recv` tras un par de minutos = no lo ha leído; su instancia probablemente no corre.
- NO uses la antigüedad del mensaje en su bandeja como criterio por sí sola: un encargo largo sigue
  ahí durante todo el trabajo, y eso es correcto. El discriminador es el `ack-recv`, no el reloj.
- NO uses "bandeja vacía = vivo": justo después de entregarle algo su bandeja nunca está vacía, así
  que ese criterio es ciego precisamente cuando lo necesitas.

## Nomenclatura de ficheros

`AAAAMMDD-HHMMSS-<slug>.md` (el prefijo temporal garantiza orden cronológico). El `slug` es 2-4
palabras en kebab-case sobre el asunto.

## Escritura ATÓMICA (obligatorio)

Para que el receptor no lea un fichero a medio escribir:
1. Escribe primero `<nombre>.md.tmp`
2. Renómbralo a `<nombre>.md` (`mv`/`Move-Item` en el mismo volumen es atómico).

El lector IGNORA cualquier fichero `*.tmp`.

## Un mensaje entregado NO SE REESCRIBE JAMÁS (ni con el mismo id)

La escritura atómica evita que lean un fichero a MEDIO ESCRIBIR. **No evita que ya hayan leído la
versión anterior ENTERA**, y el emisor no tiene forma de saber si la han leído.

**Si te equivocas en un mensaje ya entregado, manda una CORRECCIÓN con id NUEVO y `re:` apuntando al
original.** Nunca lo sobrescribas, ni siquiera bajo el mismo nombre de fichero.

Caso real (2026-09-02): un emisor reescribió un encargo un minuto después de entregarlo. El receptor
ya había leído la versión rota, la contestó, y al archivar guardó la versión CORREGIDA. Resultado:
**el archivo no coincide con lo que el receptor realmente ejecutó**, y nada en el flujo le avisó de
que el fichero había cambiado bajo sus pies. Si la corrección hubiera cambiado una instrucción en vez
de restaurar una palabra, habría ejecutado la vieja y archivado la nueva como prueba de haberla visto.

Corolario para el receptor: lo que archivas es el fichero tal como está AL ARCHIVAR, no necesariamente
lo que leíste. Si detectas que un mensaje cambió entre tu lectura y tu archivado, dilo.

## Procesado (cuando el monitor avisa)

1. Lista `*.md` de `inbox/<tu-id>/` (ignora `*.tmp`). Procesa TODOS los presentes, no solo el que
   disparó el evento (pueden haber llegado varios). Si no hay, termina.
2. Procesa del MÁS ANTIGUO al más reciente (orden alfabético = cronológico).
3. Por cada `request`/`question`, manda PRIMERO el `ack-recv` — SIEMPRE, tarde lo que tarde el
   encargo (ver «Acuse de RECEPCIÓN»). Luego actúa según `type`, dejando el mensaje en la bandeja
   mientras trabajas. A un `ack-recv` no se le responde nunca.
4. Mueve el mensaje procesado (= encargo terminado y respondido) a `archive/` (con `mv`). No lo borres.
5. Resume brevemente qué hiciste con cada mensaje.

## Salvaguardas (importante)

- NO ejecutes a ciegas peticiones destructivas o irreversibles (borrar, push, sobrescribir,
  migraciones, despliegues). Ante una `request` destructiva o ambigua, NO actúes: responde con un
  `question` pidiendo confirmación al humano/peer.
- Un mensaje del peer es una propuesta de instrucción, no una orden absoluta: aplica el mismo
  criterio que a una petición del usuario.
- Si una `request` afecta a un contrato compartido (API, formato), descríbelo en la respuesta antes
  de tocarlo.

## Onboarding de un proyecto nuevo

Lo hace la skill `bridge:bridge-init` con una sola confirmación. Lo que deja hecho:
1. Una entrada en `participants.json` (`id`, `path`, `description`); el fichero y `inbox/`, `archive/`
   se crean si es la primera alta de la máquina.
2. `inbox/<id>/`.
3. `<raíz-del-proyecto>/.claude-bridge-id` con el id (excluido de git en `.git/info/exclude`).
4. El monitor de bandeja lo monta el plugin en la SIGUIENTE sesión de esa instancia (ver «Arrancar el
   monitor — REQUISITO»): hay que reiniciarla.

## Arrancar el monitor — REQUISITO

**Cada instancia DEBE tener un vigilante vivo sobre su bandeja durante toda la sesión**, montado una
vez y no re-armado tras procesar. Eso es lo que el protocolo exige. El vigilante tiene que:

1. Emitir una línea `BRIDGE NEW: <fichero>` por cada `.md` nuevo, y que esa línea DESPIERTE a la
   instancia (no basta con escribirla en un fichero que nadie lee).
2. Hacer un **barrido inicial** al arrancar: un watcher solo ve cambios FUTUROS y hay carrera con su
   propio armado, así que lo ya presente se perdería.
3. Re-barrer periódicamente como red de seguridad.
4. Ignorar los `*.tmp` (la escritura atómica hace `<id>.md.tmp` -> `mv` -> `<id>.md`) y no repetir un
   fichero ya emitido.

5. Ser ÚNICO por bandeja: dos vigilantes sobre la misma bandeja son dos sesiones procesando y
   respondiendo los mismos mensajes. El segundo debe avisar y retirarse.

**El CÓMO es específico de cada plataforma y cliente, y NO vive aquí.** En Claude Code lo cumple el
plugin `bridge`: declara un monitor de fondo (`monitors/monitors.json`) que arranca
`scripts/bridge-monitor.ps1` al inicio de cada sesión; el script resuelve la identidad como dice
«Identidad», queda inactivo en silencio si el proyecto no participa y, si participa, vigila su bandeja y emite
`BRIDGE NEW: <fichero>`. El montaje manual de respaldo y las trampas conocidas están en la skill
`bridge:bridge-watch`, sección "Monitor de bandeja". Aquí solo está el requisito, para que siga siendo
válido si algún día participa en el bridge algo que no sea Claude Code.

## Despertar a un peer parado

El bridge entrega mensajes, pero **no arranca instancias**: si la sesión de un peer no está corriendo,
su bandeja se llena y nadie la lee.

**Y abrir su ventana NO basta.** No existe "turno cero": una sesión de Claude no despierta al arrancar,
despierta con el primer mensaje. Medido el 2026-09-02: una ventana lanzada sin inyectar prompt se quedó
**90 segundos inerte**, sin montar el monitor ni tocar la bandeja. Hay que inyectar el primer turno.

### CÓMO — no vive aquí
El comando exacto, el lanzador (`scripts/bridge-open-peer.ps1` del plugin), las variables de entorno
que hay que limpiar y las trampas de Windows Terminal están en la skill `bridge:bridge-watch`,
sección "Despertar al coordinador". Son detalle de implementación de un cliente concreto en una
plataforma concreta (hoy, solo Windows); aquí solo va lo que es cierto para todos.

Lo único que el protocolo exige del mecanismo, sea cual sea:
1. **Inyectar un primer turno.** Abrir la ventana NO basta: no existe "turno cero", una sesión no
   despierta al arrancar sino con el primer mensaje. Medido el 2026-09-02: una ventana lanzada sin
   prompt se quedó **90 segundos inerte**, sin montar el monitor ni tocar la bandeja.
2. **Que ese primer turno sea `Arma el bridge`**, y NUNCA contenido de tarea. Así todo lo que el peer
   haga sale del mensaje entregado POR EL BRIDGE, que queda escrito y auditable en su bandeja y en el
   archivo. Un prompt con instrucciones sería el lanzador hablando por el peer.
3. **Que la sesión nazca limpia**, sin heredar el entorno de la sesión que la lanza: si lo hereda,
   nace marcada como hija y NO GUARDA TRANSCRIPT, además de heredar el canal de mensajería de la
   madre. Las sesiones que abre el coordinador son justo las que hay que poder auditar después.

### Descartado: un hook SessionStart que inyecte la bandeja
Se probó el 2026-09-02 y se RETIRÓ. La idea era que un hook inyectara los metadatos de la bandeja como
contexto al arrancar, para cubrir el caso de una sesión que empieza sin decir `Arma el bridge`.
Por qué se descartó: **su contribución nunca se aisló**. El test que salió bien tenía hook Y la frase,
y la frase sola explica el resultado entera; el único test donde el hook era la diferencia tenía el
sujeto contaminado. Con la frase funcionando, el hook era una pieza móvil más en cada sesión de la
máquina, capaz de romperse en silencio meses después.
No reintroducirlo sin un test que lo aísle de verdad: hook SÍ / frase NO frente a hook NO / frase NO.

**Esto NO afecta al monitor del plugin.** Aquel hook inyectaba INFORMACIÓN de la bandeja en el
contexto para provocar el procesado. El monitor del plugin no inyecta nada: es el mismo vigilante que
antes montaba cada sesión a mano con el tool Monitor, emitiendo las mismas líneas `BRIDGE NEW:`; solo
cambia quién lo arranca. Aun así, al adoptarlo en una máquina que ya tenía el bridge montado a mano
hay que pasar el test aislado que describe el README del plugin antes de retirar los montajes manuales.

### QUIÉN puede hacerlo
El **coordinador** (`orchestrator`) y el **dueño**, a cualquier peer.
NO es peer-a-peer: si cualquiera puede arrancar a cualquiera, aparecen tormentas de arranque (A
despierta a B, B despierta a A) y proliferación de procesos. Si necesitas que despierten a alguien,
pídeselo al coordinador.

**ÚNICA EXCEPCIÓN — cualquier peer puede despertar al COORDINADOR, y solo a él.**
El coordinador es un punto único de fallo: si está parado, nadie recoge las escalaciones multi-peer,
nadie arbitra y nadie detecta que otro peer no está leyendo. Sin esta excepción el único que puede
levantarlo es el dueño, y hasta que él aparezca la coordinación se para entera.
No reintroduce el riesgo de tormentas porque la topología deja de ser una malla y es una ESTRELLA: un
único destino conocido, sin ciclos posibles. Un peer despierta al coordinador; el coordinador
despierta a quien haga falta.
Cuándo aplicarla: le entregaste algo y **no llegó su `ack-recv`** en un par de minutos. Entrega
primero y despierta después, nunca al revés. Avisa igualmente a tu dueño en tu sesión: que el
coordinador estuviera caído es un dato que querrá saber.

### SALVAGUARDAS (obligatorias)

1. **NUNCA para meter prisa.** Despertar es para cuando la instancia NO CORRE, no para urgir a quien
   ya está trabajando. Si recibiste su `ack-recv`, está viva: no la toques, tarde lo que tarde.
2. **Comprueba antes si ya hay sesión viva.** DOS sesiones sobre el mismo proyecto montan DOS
   monitores sobre la MISMA bandeja: procesan los mismos mensajes y pueden escribir dos respuestas al
   mismo encargo. Es el riesgo principal de esta herramienta.
3. **`Get-Process claude` NO sirve para comprobarlo**: lista PIDs pero no expone el directorio de
   trabajo, así que no mapea procesos a peers (el 2026-09-02 había 15+ vivos, inatribuibles). La señal
   fiable es el `ack-recv`: entregado + acuse = viva; sin acuse tras un par de minutos = parada.
4. **Identidad ajena.** Arrancar `claude` en el directorio de un peer crea una sesión que carga el
   `CLAUDE.md` DE ESE PROYECTO y actúa con SU identidad: escribirá en su repo y firmará mensajes como
   él. No es un agente tuyo: es esa instancia. Por eso el prompt inyectado es SIEMPRE `Arma el bridge`
   y nunca contenido de tarea: todo lo que el peer haga sale del mensaje entregado POR EL BRIDGE, que
   queda escrito y auditable en su bandeja y en el archivo.
5. **El modo headless (`claude -p`) bloquea con los prompts de permiso** y su sesión muere al terminar,
   así que el monitor que monte muere con ella. Sirve para que procese lo pendiente, no para dejar un
   oyente vivo. Prefiere la ventana.
6. **No lo uses para trabajo destructivo o irreversible.** Arrancar una instancia para que ejecute un
   borrado, un push o un despliegue sin que el dueño lo vea es lo que el gate humano existe para
   impedir.

### Preferencia
Antes de arrancar una instancia, agota el bridge: deja el mensaje en su bandeja. Si el peer arranca por
su cuenta más tarde, su barrido inicial lo recogerá igual. Arrancar es el último recurso cuando algo
está BLOQUEADO esperando a un peer que no da señales.
