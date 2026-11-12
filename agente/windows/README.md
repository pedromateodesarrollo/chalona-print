# print-server para Windows

El agente, la ventana, el icono junto al reloj y el servicio de Windows, todo
en C# (.NET Framework 4.8, que ya viene con Windows 10 y 11: no hay que
instalar nada). Es un solo `.exe`, lo que se descarga del hub:

| Paquete | Para |
|---|---|
| `print-server-agente-windows-x86.exe` | Windows de 32 bits. Corre también en las de 64, como proceso de 32 bits |
| `print-server-agente-windows-x64.exe` | Windows de 64 bits |

Cada uno lleva dentro el PDFium de su arquitectura (el motor de PDF de
Chrome, de bblanchon/pdfium-binaries, fijado por sha256 en `compilar.sh`): la
instalación lo deja junto al agente, y si el agente corre sin instalar lo saca
a una carpeta temporal. Hasta la 0.5.0 el agente era Dart, que no compila para
Windows de 32 bits; desde la 0.6.0 es C# con paridad completa (mismo
protocolo, mismo `agente.json`, mismo `hechos.txt`, mismo panel local): se
instala encima de un Dart y conserva la conexión.

Al abrirlo:

* **Sin instalar**: se pone la dirección del hub y una llave (`cpk_…`) y se
  pulsa «Instalar servicio». Windows pide permiso una vez; el programa se copia
  a `Archivos de programa\print-server`, conecta, y queda como servicio: sigue
  imprimiendo después de reiniciar, aunque nadie inicie sesión. Sin llave no se
  instala: un servicio sin conectar no imprime.
* **Instalado pero desconectado** (tras «Desconectar»): el servicio sigue
  puesto, esperando; el botón dice «Conectar».
* **Conectado**: enseña si está conectado, desde cuándo, cuánto lleva impreso,
  las impresoras (con «Imprimir página de prueba») y el registro del agente.

## Qué queda instalado

| Qué | Dónde |
|---|---|
| La ventana y el agente | `C:\Program Files\print-server\` (`print-server.exe`, `print-server-agente.exe` —el mismo programa—, `pdfium.dll`) |
| El servicio | `print-server`, automático, cuenta SYSTEM: arranca con Windows aunque nadie inicie sesión |
| La conexión (con la credencial) | `C:\ProgramData\print-server\agente.json`, solo SYSTEM y administradores |
| El registro | `C:\ProgramData\print-server\agente.log` |
| El icono junto al reloj | `HKLM\…\Run\print-server` → `print-server.exe --bandeja` |
| El acceso | menú Inicio → print-server |

El agente no es el servicio: el servicio es `print-server.exe --servicio`, que
arranca `print-server-agente.exe correr` (una copia del mismo .exe) y lo vuelve
a levantar si se cae. El agente acepta las órdenes del de Dart —`correr`,
`configurar`, `impresoras`, `probar`, `imprimir`, `--version`— y su código
está en `src/agente/`.

## Desde la línea de órdenes

Todo lo de la ventana se puede hacer sin ella, en una consola de administrador
(es lo que usa `agente/instalador/instalar.ps1`):

```powershell
Start-Process print-server.exe -Wait -ArgumentList '--instalar','--hub','https://print.chalonasoft.com','--llave','cpk_...','--resultado','r.txt'
Start-Process print-server.exe -Wait -ArgumentList '--desconectar'
Start-Process print-server.exe -Wait -ArgumentList '--desinstalar'
```

Es un programa de ventanas: sin `-Wait` PowerShell no espera, y el mensaje
final queda en el archivo de `--resultado`.

## Versiones anteriores

Instalar encima retira lo que hubiera: las tareas programadas de la 0.2 y el
servicio de la 0.3.0 (se reconoce por la carpeta de su programa). La conexión se
conserva, también la de `ProgramData\chalona-print`, la carpeta de antes del
cambio de nombre: no hace falta una llave nueva.

## Compilar

```bash
./compilar.sh              # en Linux (o Git Bash): dist/print-server-agente-windows-{x86,x64}.exe
../publicar.sh --windows x86 --hub https://print.chalonasoft.com --llave cpk_...
```

No hace falta Windows para compilar: un net48 compila en cualquier sistema con
el SDK de .NET. GitHub Actions lo hace en `.github/workflows/binarios.yml`.

## Pruebas

* `pruebas/` — lo que no necesita Windows (leer JSON, citar argumentos, qué
  enseña la ventana en cada situación, y las pruebas del agente de Dart
  portadas: lenguaje de cada etiquetadora, página de prueba, papel, hechos):
  `cd pruebas && dotnet run`.
* `pruebas/humo.ps1` — instala de verdad, imprime en la impresora falsa, mata al
  agente para ver que vuelve, desconecta, desinstala y saca una captura de la
  ventana. **Solo para una máquina desechable**: corre en cada cambio en
  GitHub Actions (`.github/workflows/windows.yml`), con los dos paquetes.

El icono sale de `herramientas/icono.py` (sin dependencias).
