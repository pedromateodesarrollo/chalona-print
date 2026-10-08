# Compila el paquete de Windows: el agente (Dart) metido dentro de la ventana (C#).
#
#   pwsh agente/windows/compilar.ps1
#
# Deja en agente/windows/dist/:
#   print-server-agente.exe               el agente solo (lo que va dentro)
#   print-server-agente-windows-x64.exe   EL PAQUETE: lo que se publica en el hub
#
# Tiene que correr en Windows: `dart compile exe` genera para el sistema donde
# corre. La ventana sola sí compila en Linux (`dotnet build`), pero sin el
# agente dentro no puede instalar nada.
param(
  [string]$Salida = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$agente = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force -Path $Salida | Out-Null
$exeAgente = Join-Path $Salida 'print-server-agente.exe'

Write-Host '-> compilando el agente (Dart)'
Push-Location $agente
try {
  dart pub get | Out-Null
  dart compile exe bin/print_server_agente.dart -o $exeAgente
  if ($LASTEXITCODE -ne 0) { throw 'No compiló el agente.' }
} finally {
  Pop-Location
}

Write-Host '-> compilando la ventana (C#) con el agente dentro'
$compilado = Join-Path $Salida 'compilado'
dotnet build (Join-Path $PSScriptRoot 'print-server.csproj') -c Release -nologo `
  "-p:AgenteExe=$exeAgente" -p:ExigirAgente=true -o $compilado
if ($LASTEXITCODE -ne 0) { throw 'No compiló la ventana.' }

$paquete = Join-Path $Salida 'print-server-agente-windows-x64.exe'
Copy-Item (Join-Path $compilado 'print-server.exe') $paquete -Force

$mb = [math]::Round((Get-Item $paquete).Length / 1MB, 1)
$sha = (Get-FileHash $paquete -Algorithm SHA256).Hash.ToLower()
Write-Host "   $paquete · $mb MB · sha256 $($sha.Substring(0,16))…"
