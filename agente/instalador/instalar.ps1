# Instalador del agente de print-server para Windows, sin ventana.
#
# En PowerShell como administrador:
#   & ([scriptblock]::Create((irm https://TU-HUB/descargas/instalar.ps1))) `
#       -Hub https://TU-HUB -Llave cpk_...
#
# Quien prefiera no pegar comandos: baja el .exe y haz doble clic. Es el mismo
# programa: abre una ventana, se conecta y queda como servicio de Windows.
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

$exe = Join-Path $env:TEMP 'print-server-agente-windows-x64.exe'
Write-Host "-> bajando print-server de $Hub"
Invoke-WebRequest -Uri "$Hub/descargas/print-server-agente-windows-x64.exe" `
  -OutFile $exe -UseBasicParsing

Write-Host '-> conectando con el hub e instalando el servicio'
$resultado = Join-Path $env:TEMP "print-server-$([guid]::NewGuid().ToString('N')).txt"
# Es un programa de ventanas: sin -Wait, PowerShell no espera a que termine ni
# se entera de cómo salió.
$p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
  '--instalar', '--hub', "`"$Hub`"", '--llave', "`"$Llave`"", '--nombre', "`"$Nombre`"",
  '--resultado', "`"$resultado`""
)
$mensaje = if (Test-Path $resultado) { Get-Content $resultado -Raw -Encoding UTF8 } else { '' }
Remove-Item $resultado, $exe -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) { throw "No se pudo instalar: $mensaje" }

Write-Host ''
Write-Host $mensaje
Write-Host "La computadora «$Nombre» ya aparece en el panel del hub."
Write-Host 'Aquí se ve en «print-server», en el menú Inicio, o en el icono junto al reloj.'
