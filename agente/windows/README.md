# print-server para Windows

La ventana, el icono junto al reloj y el servicio de Windows. Es un solo `.exe`
con el agente (Dart) dentro: lo que se descarga del hub como
`print-server-agente-windows-x64.exe`.

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
| La ventana y el agente | `C:\Program Files\print-server\` (`print-server.exe`, `print-server-agente.exe`) |
| El servicio | `print-server`, automático, cuenta SYSTEM: arranca con Windows aunque nadie inicie sesión |
| La conexión (con la credencial) | `C:\ProgramData\print-server\agente.json`, solo SYSTEM y administradores |
| El registro | `C:\ProgramData\print-server\agente.log` |
| El icono junto al reloj | `HKLM\…\Run\print-server` → `print-server.exe --bandeja` |
| El acceso | menú Inicio → print-server |

El agente no es el servicio: el servicio es `print-server.exe --servicio`, que
arranca `print-server-agente.exe correr` y lo vuelve a levantar si se cae. Dart
corre en un solo hilo y un servicio de Windows tiene que contestar al sistema
desde otro; por eso el servicio está en C# y el agente sigue siendo el mismo de
Linux y macOS.

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

```powershell
pwsh compilar.ps1          # en Windows: deja dist\print-server-agente-windows-x64.exe
```

La ventana sola compila también en Linux (`dotnet build -c Release`), pero sin
el agente dentro no puede instalar nada: `dart compile exe` no cruza de
sistema. GitHub Actions compila el paquete en Windows
(`.github/workflows/binarios.yml`).

## Pruebas

* `pruebas/` — lo que no necesita Windows (leer JSON, citar argumentos, qué
  enseña la ventana en cada situación): `cd pruebas && dotnet run`.
* `pruebas/humo.ps1` — instala de verdad, imprime en la impresora falsa, mata al
  agente para ver que vuelve, desconecta, desinstala y saca una captura de la
  ventana. **Solo para una máquina desechable**: corre en cada cambio en
  GitHub Actions (`.github/workflows/windows.yml`).

El icono sale de `herramientas/icono.py` (sin dependencias).
