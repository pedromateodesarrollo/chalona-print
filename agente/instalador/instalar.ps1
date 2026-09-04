# Instalador del agente de chalona-print para Windows.
#
# En PowerShell como administrador:
#   & ([scriptblock]::Create((irm https://TU-HUB/descargas/instalar.ps1))) `
#       -Hub https://TU-HUB -Llave cpk_...
#
# Quien prefiera no pegar comandos: baja el .exe y haz doble clic. Hace lo
# mismo, preguntando los dos datos en el navegador.
param(
  [Parameter(Mandatory = $true)][string]$Hub,
  [Parameter(Mandatory = $true)][string]$Llave,
  [string]$Nombre = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

$esAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
  # El servicio arranca con la máquina y la configuración vive en ProgramData:
  # las dos cosas necesitan permisos de administrador.
  throw 'Abre PowerShell como administrador y vuelve a correrlo.'
}

$destino = Join-Path $env:ProgramFiles 'chalona-print'
New-Item -ItemType Directory -Force -Path $destino | Out-Null
$exe = Join-Path $destino 'chalona-print-agente.exe'

Write-Host "-> bajando el agente de $Hub"
Invoke-WebRequest -Uri "$Hub/descargas/chalona-print-agente-windows-x64.exe" `
  -OutFile $exe -UseBasicParsing

Write-Host '-> conectando con el hub'
& $exe configurar --hub $Hub --llave $Llave --nombre $Nombre
if ($LASTEXITCODE -ne 0) { throw 'No se pudo conectar con el hub.' }

Write-Host '-> instalando el servicio'
& $exe instalar
if ($LASTEXITCODE -ne 0) { throw 'No se pudo instalar el servicio.' }

Write-Host ''
Write-Host "Listo. La computadora «$Nombre» ya aparece en el panel del hub."
Write-Host 'Panel de esta máquina: http://127.0.0.1:7717'
