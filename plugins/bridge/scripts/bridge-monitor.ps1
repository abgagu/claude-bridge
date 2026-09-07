# BRIDGE - vigilante de bandeja de entrada.
#
# Lo arranca el plugin `bridge` al inicio de cada sesion (monitors/monitors.json). Cada linea
# "BRIDGE NEW: <fichero>" que escribe en stdout llega a la sesion como notificacion y dispara la
# skill bridge:bridge-watch. En reposo no emite nada.
#
# Uso manual (solo si el plugin no pudo montarlo; ver SKILL.md, "Monitor de bandeja"):
#   powershell -NoProfile -File bridge-monitor.ps1 -Project <raiz-del-proyecto> [-Id <id>] [-Root <dir-estado>]
#
# Identidad (BRIDGE.md, "Identidad"), en este orden:
#   1) marcador .claude-bridge-id en -Project o en un directorio ancestro;
#   2) entrada de participants.json cuyo path sea prefijo de -Project (gana el prefijo mas largo);
#   3) ninguna -> este proyecto NO participa en el bridge: sale en silencio con codigo 0 (auto-gate).
#
# Un solo vigilante por bandeja y sesion de usuario (mutex con nombre): una segunda sesion sobre el
# mismo proyecto, o un /reload-plugins con el vigilante anterior aun vivo, avisa y sale en vez de
# duplicar notificaciones.
param(
	[string]$Project = (Get-Location).Path,
	[string]$Id = '',
	[string]$Root = (Join-Path $env:USERPROFILE '.claude\bridge')
)
$ErrorActionPreference = 'Continue'

function Emit([string]$line) {
	[Console]::Out.WriteLine($line)
	[Console]::Out.Flush()
}
function Norm([string]$p) {
	return (($p -replace '\\', '/').TrimEnd('/')).ToLowerInvariant()
}

function Resolve-BridgeId {
	# 1) marcador, subiendo directorios
	$d = $Project
	while ($d) {
		$m = Join-Path $d '.claude-bridge-id'
		if (Test-Path -LiteralPath $m -PathType Leaf) {
			$v = (Get-Content -LiteralPath $m -Raw) -replace '\s', ''
			if ($v) { return $v }
		}
		$parent = Split-Path -Parent $d
		if (-not $parent -or $parent -eq $d) { break }
		$d = $parent
	}
	# 2) roster: path de participants.json que sea prefijo del proyecto
	$roster = Join-Path $Root 'participants.json'
	if (-not (Test-Path -LiteralPath $roster -PathType Leaf)) { return '' }
	try { $j = Get-Content -LiteralPath $roster -Raw | ConvertFrom-Json } catch { return '' }
	$np = Norm $Project
	$best = ''
	$bestLen = -1
	foreach ($prop in $j.PSObject.Properties) {
		$pp = Norm ([string]$prop.Value.path)
		if ($pp -and ($np -eq $pp -or $np.StartsWith($pp + '/')) -and $pp.Length -gt $bestLen) {
			$best = $prop.Name
			$bestLen = $pp.Length
		}
	}
	return $best
}

if (-not $Id) { $Id = Resolve-BridgeId }
if (-not $Id) { exit 0 }   # auto-gate: no participa, sin ruido

$dir = Join-Path $Root "inbox\$Id"
if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
	Emit "BRIDGE ERROR: inbox for '$Id' not found: $dir (run /bridge:bridge-init)"
	exit 1
}

# Un vigilante por bandeja. El SO libera el mutex cuando el proceso muere.
$mutex = New-Object System.Threading.Mutex($false, "Local\claude-bridge-inbox-$Id")
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
	Emit "BRIDGE WARN: inbox '$Id' already has a watcher (duplicate session or plugin reload); this one exits"
	exit 0
}

# stderr no genera notificacion: solo queda en la salida del monitor para diagnostico.
[Console]::Error.WriteLine("bridge: watching $dir as '$Id'")

$seen = New-Object System.Collections.Generic.HashSet[string]
function Emit-New {
	Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
		$n = $_.Name
		if ($n -notlike '*.tmp' -and -not $seen.Contains($n)) {
			[void]$seen.Add($n)
			Emit ('BRIDGE NEW: ' + $n)
		}
	}
}

$w = New-Object IO.FileSystemWatcher $dir, '*.md'
$w.NotifyFilter = [IO.NotifyFilters]::FileName
Emit-New   # barrido inicial: emite lo que ya hubiera al arrancar
while ($true) {
	# Despierta en cuanto llega Created/Renamed; si no, cada 5 s re-barre como red de seguridad.
	$w.WaitForChanged([IO.WatcherChangeTypes]'Created,Renamed', 5000) | Out-Null
	Emit-New
}
