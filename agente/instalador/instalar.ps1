# Instalador del agente de print-server para Windows, sin ventana.
#
# En PowerShell como administrador:
#   & ([scriptblock]::Create((irm https://TU-HUB/descargas/instalar.ps1))) `
#       -Hub https://TU-HUB -Llave cpk_...
#
# Quien prefiera no pegar comandos: baja el .exe y haz doble clic. Es el mismo
# programa: abre una ventana, se conecta y queda como servicio de Windows.
#
# Elige solo el paquete de la arquitectura de esta Windows: el de 64 bits si el
# sistema es de 64, el de 32 (x86) si no. El de 32 corre en las dos: si el hub
# todavía no publica el de 64, se usa ese.
param(
  [Parameter(Mandatory = $true)][string]$Hub,
  [Parameter(Mandatory = $true)][string]$Llave,
  [string]$Nombre = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$Hub = $Hub.TrimEnd('/')

$esAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
  # El servicio arranca con la máquina y la configuración vive en ProgramData:
  # las dos cosas necesitan permisos de administrador.
  throw 'Abre PowerShell como administrador y vuelve a correrlo.'
}

$candidatos = if ([Environment]::Is64BitOperatingSystem) { @('x64', 'x86') } else { @('x86') }
$publicados = @()
try { $publicados = @((Invoke-RestMethod -Uri "$Hub/v1/descargas" -UseBasicParsing).descargas | ForEach-Object { $_.archivo }) } catch { }
$archivo = $null
foreach ($arq in $candidatos) {
  $n = "print-server-agente-windows-$arq.exe"
  if ($publicados.Count -eq 0 -or $publicados -contains $n) { $archivo = $n; break }
}
if (-not $archivo) { throw "El hub no publica el agente para esta Windows ($($candidatos -join ' o '))." }

$exe = Join-Path $env:TEMP $archivo
Write-Host "-> bajando $archivo de $Hub"
Invoke-WebRequest -Uri "$Hub/descargas/$archivo" -OutFile $exe -UseBasicParsing

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
