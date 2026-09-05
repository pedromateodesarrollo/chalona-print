# Compila el agente para Windows y lo publica en un hub.
#
# Windows es el único sistema donde el ejecutable tiene que salir de una
# máquina Windows: `dart compile exe` genera para el sistema donde corre, y no
# hay forma de cruzar. Este script es ese puente.
#
#   .\publicar.ps1 -Hub https://print.chalonasoft.com -Llave cpk_...
#
# La llave tiene que ser de administrador y de la organización que publica en
# ese hub (por defecto la 1, la que lo levantó): las descargas son del hub
# entero, no de una organización.
param(
  [Parameter(Mandatory = $true)][string]$Hub,
  [Parameter(Mandatory = $true)][string]$Llave,
  [switch]$SoloCompilar
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$archivo = 'print-server-agente-windows-x64.exe'

Write-Host '-> compilando'
dart pub get | Out-Null
dart compile exe bin/print_server_agente.dart -o $archivo
if ($LASTEXITCODE -ne 0) { throw 'La compilación falló.' }

$local = (Get-FileHash $archivo -Algorithm SHA256).Hash.ToLower()
$mb = [math]::Round((Get-Item $archivo).Length / 1MB, 1)
Write-Host "   $archivo · $mb MB · sha256 $($local.Substring(0,16))…"

if ($SoloCompilar) {
  Write-Host 'Listo (sin publicar).'
  exit 0
}

Write-Host "-> publicando en $Hub"
try {
  $r = Invoke-RestMethod -Method Post -Uri "$Hub/v1/descargas/$archivo" `
    -Headers @{ authorization = "Bearer $Llave" } `
    -ContentType 'application/octet-stream' -InFile $archivo
} catch {
  # El hub explica por qué en el cuerpo; sin esto solo se vería «400».
  $detalle = $_.ErrorDetails.Message
  if ($detalle) { throw "El hub lo rechazó: $detalle" } else { throw }
}

# Que el hub confirme el mismo sha256 es la prueba de que llegó entero: es lo
# que separa «subió» de «subió bien».
if ($r.sha256 -ne $local) {
  throw "El hub guardó otra cosa (sha256 $($r.sha256)). No lo des por publicado."
}

Write-Host ''
Write-Host "Publicado: $Hub$($r.url)"
Write-Host 'Ya aparece en el panel, en «Instalar agente».'
