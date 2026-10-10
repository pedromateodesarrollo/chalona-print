# Compila el paquete de Windows: el agente (Dart) metido dentro de la ventana (C#).
#
#   pwsh agente/windows/compilar.ps1
#
# Deja en agente/windows/dist/:
#   print-server-agente.exe               el agente solo (lo que va dentro)
#   pdfium.dll                            el motor de PDF (va dentro también)
#   print-server-agente-windows-x64.exe   EL PAQUETE: lo que se publica en el hub
#
# PDFium es el motor de PDF de Chrome, compilado por bblanchon/pdfium-binaries.
# Va FIJADO por versión y por sha256: un binario que se mete en computadoras
# ajenas no se baja «el último» sin mirar. Para subirlo, cambiar las dos cosas
# juntas (la huella sale de `sha256sum pdfium-win-x64.tgz`).
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

$pdfiumVersion = 'chromium/8086'
$pdfiumSha256 = '1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d'
$pdfiumDll = Join-Path $Salida 'pdfium.dll'
$pdfiumLicencias = Join-Path $Salida 'pdfium-licencias.txt'

Write-Host "-> PDFium $pdfiumVersion"
$tgz = Join-Path $Salida 'pdfium-win-x64.tgz'
if (-not (Test-Path $tgz) -or (Get-FileHash $tgz -Algorithm SHA256).Hash.ToLower() -ne $pdfiumSha256) {
  Invoke-WebRequest -UseBasicParsing -OutFile $tgz `
    -Uri "https://github.com/bblanchon/pdfium-binaries/releases/download/$pdfiumVersion/pdfium-win-x64.tgz"
}
$sha = (Get-FileHash $tgz -Algorithm SHA256).Hash.ToLower()
if ($sha -ne $pdfiumSha256) { throw "PDFium no es el esperado (sha256 $sha)." }
$pdfiumDir = Join-Path $Salida 'pdfium'
Remove-Item -Recurse -Force $pdfiumDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $pdfiumDir | Out-Null
tar -xzf $tgz -C $pdfiumDir
if ($LASTEXITCODE -ne 0) { throw 'No se pudo abrir el paquete de PDFium.' }
Copy-Item (Join-Path $pdfiumDir 'bin/pdfium.dll') $pdfiumDll -Force
# Sus licencias viajan con él: van junto a la DLL en Archivos de programa.
$textos = @(Get-Item (Join-Path $pdfiumDir 'LICENSE')) + @(Get-ChildItem (Join-Path $pdfiumDir 'licenses') -File)
($textos | ForEach-Object { "==== $($_.Name) ====`n" + (Get-Content $_.FullName -Raw) }) -join "`n" |
  Set-Content -Path $pdfiumLicencias -Encoding UTF8

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
  "-p:AgenteExe=$exeAgente" "-p:PdfiumDll=$pdfiumDll" "-p:PdfiumLicencias=$pdfiumLicencias" `
  -p:ExigirAgente=true -o $compilado
if ($LASTEXITCODE -ne 0) { throw 'No compiló la ventana.' }

$paquete = Join-Path $Salida 'print-server-agente-windows-x64.exe'
Copy-Item (Join-Path $compilado 'print-server.exe') $paquete -Force

$mb = [math]::Round((Get-Item $paquete).Length / 1MB, 1)
$sha = (Get-FileHash $paquete -Algorithm SHA256).Hash.ToLower()
Write-Host "   $paquete · $mb MB · sha256 $($sha.Substring(0,16))…"
