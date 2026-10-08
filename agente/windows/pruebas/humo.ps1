# Prueba de punta a punta del paquete de Windows, en una máquina de verdad.
#
#   pwsh agente/windows/pruebas/humo.ps1 -Paquete dist/print-server-agente-windows-x64.exe
#
# INSTALA Y DESINSTALA print-server en la máquina donde corre, y escribe en
# ProgramData y en Archivos de programa. Es para la máquina desechable de la
# integración continua (GitHub Actions), no para la computadora de nadie.
#
# Sin hub: se le da al agente una conexión inventada con el driver «falso», que
# escribe los trabajos en una carpeta. Así se prueba lo que solo existe en
# Windows —el servicio, el job, la instalación, la limpieza de lo viejo— sin
# depender de nada de fuera.
param(
  [Parameter(Mandatory = $true)][string]$Paquete,
  [string]$Capturas = (Join-Path $PSScriptRoot 'capturas')
)

$ErrorActionPreference = 'Stop'
$Paquete = (Resolve-Path $Paquete).Path
New-Item -ItemType Directory -Force -Path $Capturas | Out-Null

$datos = Join-Path $env:ProgramData 'print-server'
$config = Join-Path $datos 'agente.json'
$programa = Join-Path $env:ProgramFiles 'print-server'
$salidaFalsa = Join-Path $env:TEMP 'print-server-falso'
$fallos = 0

function Paso($texto) { Write-Host "`n== $texto" }
function Bien($texto) { Write-Host "   ok  $texto" }
function Mal($texto) { Write-Host "   MAL $texto"; $script:fallos++ }
function Comprueba($cond, $texto) { if ($cond) { Bien $texto } else { Mal $texto } }

function Corre([string[]]$argumentos) {
  $resultado = Join-Path $env:TEMP "humo-$([guid]::NewGuid().ToString('N')).txt"
  $p = Start-Process -FilePath $script:exe -ArgumentList ($argumentos + @('--resultado', "`"$resultado`"")) -Wait -PassThru
  $mensaje = if (Test-Path $resultado) { Get-Content $resultado -Raw -Encoding UTF8 } else { '' }
  Remove-Item $resultado -ErrorAction SilentlyContinue
  Write-Host "   [$($argumentos[0]) → $($p.ExitCode)] $mensaje"
  return @{ codigo = $p.ExitCode; mensaje = $mensaje }
}

function EscribeConfig($ruta) {
  New-Item -ItemType Directory -Force -Path (Split-Path $ruta) | Out-Null
  # Un hub que no existe: el agente reintenta sin parar, y su panel contesta igual.
  @{
    hub = 'http://127.0.0.1:9'; credencial = 'cpa_prueba'; agente = 99; nombre = 'humo'
    huella = 'humo'; driver = 'falso'; puerto_panel = 7717; salida_falsa = $salidaFalsa
  } | ConvertTo-Json | Set-Content -Path $ruta -Encoding UTF8
}

function Estado {
  try { return Invoke-RestMethod -Uri 'http://127.0.0.1:7717/estado.json' -TimeoutSec 3 } catch { return $null }
}

function EsperaEstado([int]$segundos = 40) {
  for ($i = 0; $i -lt $segundos; $i++) {
    $e = Estado
    if ($e) { return $e }
    Start-Sleep -Seconds 1
  }
  return $null
}

function Servicio($nombre) { Get-Service -Name $nombre -ErrorAction SilentlyContinue }

function MuestraRegistro {
  $r = Join-Path $datos 'agente.log'
  if (Test-Path $r) { Write-Host '   --- agente.log ---'; Get-Content $r -Tail 30 | ForEach-Object { "   $_" } }
}

# La ventana se lanza desde una copia con el nombre con que se descarga.
$script:exe = Join-Path $env:TEMP 'print-server-agente-windows-x64.exe'
Copy-Item $Paquete $script:exe -Force

# ---------------------------------------------------------------------------
Paso 'una 0.3.0 vieja: servicio con el nombre de antes y su conexión en ProgramData\chalona-print'
EscribeConfig (Join-Path $env:ProgramData 'chalona-print\agente.json')
$viejo = Join-Path $env:ProgramData 'chalona-print\viejo'
New-Item -ItemType Directory -Force -Path $viejo | Out-Null
# Un servicio que no arranca de verdad basta: lo que se prueba es que lo encuentra y lo quita.
& sc.exe create chalona-print-agente binPath= "`"$viejo\chalona-print-agente.exe`" --servicio" start= demand | Out-Null
& schtasks.exe /create /tn chalona-print-agente-bandeja /tr 'cmd.exe /c exit' /sc onlogon /f | Out-Null
Comprueba ($null -ne (Servicio 'chalona-print-agente')) 'servicio viejo puesto'

# ---------------------------------------------------------------------------
Paso 'instalar: debe quitar lo viejo, traer su conexión y quedar como servicio'
$r = Corre @('--instalar')
Comprueba ($r.codigo -eq 0) 'instala sin error'
Comprueba ($null -eq (Servicio 'chalona-print-agente')) 'quitó el servicio viejo'
& schtasks.exe /query /tn chalona-print-agente-bandeja 2>$null | Out-Null
Comprueba ($LASTEXITCODE -ne 0) 'quitó la tarea vieja'
Comprueba (Test-Path $config) 'trajo la conexión vieja a ProgramData\print-server'
Comprueba (-not (Test-Path (Join-Path $env:ProgramData 'chalona-print\agente.json'))) 'borró la conexión de la carpeta vieja'
Comprueba (Test-Path (Join-Path $programa 'print-server.exe')) 'copió la ventana a Archivos de programa'
Comprueba (Test-Path (Join-Path $programa 'print-server-agente.exe')) 'sacó el agente a Archivos de programa'
$s = Servicio 'print-server'
Comprueba ($s -and $s.Status -eq 'Running') "servicio print-server en marcha ($($s.Status))"
Comprueba ($s -and $s.StartType -eq 'Automatic') "arranca con Windows ($($s.StartType))"
$run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).'print-server'
Comprueba ($run -like '*--bandeja') 'icono de la bandeja al iniciar sesión'

$acl = Get-Acl $config
$usuarios = $acl.Access | Where-Object { $_.IdentityReference -match 'Users|Usuarios' }
Comprueba ($acl.AreAccessRulesProtected -and -not $usuarios) 'la credencial queda solo para SYSTEM y administradores'

# ---------------------------------------------------------------------------
Paso 'el agente, arrancado por el servicio'
$e = EsperaEstado
if (-not $e) { MuestraRegistro }
Comprueba ($null -ne $e) 'el panel del agente contesta'
if ($e) {
  Comprueba ($e.modo -eq 'servicio') "dice que corre como servicio ($($e.modo))"
  Comprueba ($e.version -eq '0.4.0') "versión del agente ($($e.version))"
  Comprueba ($e.agente -eq 99) 'conserva el número de agente de la conexión vieja'
  Comprueba (@($e.impresoras).Count -ge 1) "ve impresoras ($(@($e.impresoras).Count))"
  $p = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:7717/probar' -ContentType 'application/json' `
    -Body (@{ impresora = 'falsa-etiquetas' } | ConvertTo-Json)
  Comprueba ($p.ok) "página de prueba ($($p.lenguaje))"
  Comprueba (@(Get-ChildItem $salidaFalsa -ErrorAction SilentlyContinue).Count -ge 1) 'la prueba llegó a la impresora falsa'
}
# El hub inventado no contesta y el agente lo anota con tilde: si la salida no
# llegara en UTF-8, aquí saldría «conexiÃ³n».
Comprueba ((Get-Content (Join-Path $datos 'agente.log') -Raw -Encoding UTF8) -match 'conexión caída') 'registro en disco, en UTF-8'

# ---------------------------------------------------------------------------
Paso 'la ventana'
$png = Join-Path $Capturas 'ventana.png'
$v = Start-Process -FilePath (Join-Path $programa 'print-server.exe') -ArgumentList @('--captura', '--archivo', "`"$png`"") -PassThru
if (-not $v.WaitForExit(60000)) { $v.Kill(); Mal 'la ventana no terminó la captura' }
Comprueba (Test-Path $png) 'captura de la ventana'
if (Test-Path "$png.error.txt") { Get-Content "$png.error.txt" }

# ---------------------------------------------------------------------------
Paso 'parar el servicio no deja agentes sueltos'
Stop-Service print-server
Start-Sleep -Seconds 2
Comprueba (-not (Get-Process print-server-agente -ErrorAction SilentlyContinue)) 'no queda print-server-agente corriendo'
Start-Service print-server
Comprueba ($null -ne (EsperaEstado)) 'vuelve a arrancar'

Paso 'si el agente muere, el servicio lo levanta'
Get-Process print-server-agente | Stop-Process -Force
Start-Sleep -Seconds 2
Comprueba ($null -ne (EsperaEstado 30)) 'el agente volvió solo'

# ---------------------------------------------------------------------------
Paso 'desconectar: borra la credencial, el servicio se queda esperando'
$r = Corre @('--desconectar')
Comprueba ($r.codigo -eq 0) 'desconecta sin error'
Comprueba (-not (Test-Path $config)) 'sin credencial en disco'
Comprueba ((Servicio 'print-server').Status -eq 'Running') 'el servicio sigue puesto, esperando'
Start-Sleep -Seconds 3
Comprueba ($null -eq (Estado)) 'sin conexión no hay agente corriendo'

Paso 'volver a conectar: el servicio lo nota solo'
EscribeConfig $config
Comprueba ($null -ne (EsperaEstado 30)) 'el agente arranca en cuanto hay conexión'

Paso 'conectar con un hub que no contesta: dice por qué y no toca lo que ya funciona'
$r = Corre @('--instalar', '--hub', 'http://127.0.0.1:9', '--llave', 'cpk_no_existe')
Comprueba ($r.codigo -ne 0) 'falla'
Comprueba ($r.mensaje -match 'No pude llegar al hub') "explica: $($r.mensaje)"
Comprueba ((Servicio 'print-server').Status -eq 'Running') 'el servicio sigue en marcha'
Comprueba ($null -ne (EsperaEstado 10)) 'y el agente sigue contestando'

# ---------------------------------------------------------------------------
Paso 'desinstalar'
$r = Corre @('--desinstalar')
Comprueba ($r.codigo -eq 0) 'desinstala sin error'
Comprueba ($null -eq (Servicio 'print-server')) 'sin servicio'
Comprueba (-not (Test-Path $datos)) 'sin ProgramData\print-server (ni credencial)'
$run = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).'print-server'
Comprueba (-not $run) 'sin icono al iniciar sesión'
for ($i = 0; $i -lt 30 -and (Test-Path $programa); $i++) { Start-Sleep -Seconds 1 }
Comprueba (-not (Test-Path $programa)) 'sin Archivos de programa\print-server'

Write-Host ''
if ($fallos -gt 0) { Write-Host "$fallos comprobaciones fallaron"; exit 1 }
Write-Host 'Todo bien.'
