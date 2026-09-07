# BRIDGE - abre una sesion de Claude LIMPIA en el directorio de un peer.
# Uso:  powershell -NoExit -File bridge-open-peer.ps1 -Peer <id> [-Prompt "<texto>"] [-Ultracode]
#
# POR QUE EXISTE: si se lanza `claude` heredando el entorno de otra sesion de Claude, la nueva
# arranca marcada como HIJA -> NO guarda transcript y ademas hereda el socket y el token de
# mensajeria de la sesion madre. Este lanzador limpia esas variables antes de arrancar.
#
# Quien puede usarlo: el coordinador (`orchestrator`) y el dueno, sobre cualquier peer; cualquier
# peer, SOLO sobre el coordinador. Ver BRIDGE.md, "Despertar a un peer parado".
#
# Se lanza como PESTANA de una unica ventana de Windows Terminal llamada `bridge-peers`
# (nunca `-w 0`, nunca `Start-Process wt` a pelo; el comando exacto esta en la skill bridge:bridge-watch).
#
# -Ultracode: APAGADO por defecto. Arranca la sesion del peer con ultracode (xhigh + orquestacion de
# workflows por defecto). Se pasa como FICHERO de settings, no como JSON en linea, para no depender de
# cuantas capas de escapado cruza el texto. Usalo solo cuando el encargo justifique fan-out real
# (auditorias, barridos, migraciones); para leer un mensaje y acusar recibo es desproporcionado.
param(
	[Parameter(Mandatory=$true)][string]$Peer,
	[string]$Prompt = 'Arma el bridge',
	[switch]$Ultracode
)

$roster = Join-Path $env:USERPROFILE '.claude\bridge\participants.json'
if (-not (Test-Path -LiteralPath $roster)) { Write-Error "No encuentro participants.json en $roster (ejecuta /bridge:bridge-init)"; exit 1 }

$entry = (Get-Content -LiteralPath $roster -Raw | ConvertFrom-Json).$Peer
if (-not $entry) { Write-Error "El peer '$Peer' no esta en participants.json"; exit 1 }

$dir = $entry.path
if (-not (Test-Path -LiteralPath $dir)) { Write-Error "El directorio del peer no existe: $dir"; exit 1 }

# Limpia lo heredado de la sesion madre. Sin esto la sesion nueva nace marcada como HIJA (no guarda
# transcript) y hereda el socket y el token de mensajeria de la sesion madre.
foreach ($v in @(
	'CLAUDE_CODE_CHILD_SESSION',
	'CLAUDE_CODE_SESSION_ID',
	'CLAUDE_CODE_BRIDGE_SESSION_ID',
	'CLAUDE_CODE_MESSAGING_SOCKET',
	'CLAUDE_CODE_MESSAGING_TOKEN',
	'CLAUDE_CODE_ENTRYPOINT',
	'CLAUDE_PID',
	'CLAUDECODE'
)) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }

# NO_COLOR SE FIJA AQUI, NO SE HEREDA:
#   1. La salida de las herramientas no viene cargada de codigos ANSI.
#   2. El logo sale GRIS en vez de naranja: permite distinguir DE UN VISTAZO que sesiones abrio
#      Claude y cuales abrio el humano. El gris es una SENAL, no un defecto. NO "arreglarlo".
# Heredar una senal la hace depender de quien lanza; fijarla la hace cierta siempre.
$env:NO_COLOR = '1'

Set-Location $dir

$claudeArgs = @()
if ($Ultracode) {
	# Primero el fichero del plugin (junto a este script); si no, la copia en el estado del bridge.
	$candidates = @(
		(Join-Path $PSScriptRoot '..\templates\ultracode.settings.json'),
		(Join-Path $env:USERPROFILE '.claude\bridge\ultracode.settings.json')
	)
	$ucFile = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
	if ($ucFile) {
		$ucFile = (Resolve-Path -LiteralPath $ucFile).Path
		$claudeArgs += @('--settings', $ucFile)
		Write-Host "bridge: ULTRACODE activado para esta sesion de '$Peer'" -ForegroundColor Yellow
	} else {
		Write-Warning "bridge: no encuentro ultracode.settings.json - arranco SIN ultracode"
	}
}
$claudeArgs += $Prompt

Write-Host "bridge: abriendo sesion limpia de '$Peer' en $dir" -ForegroundColor Cyan
claude @claudeArgs
