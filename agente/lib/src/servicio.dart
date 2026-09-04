import 'dart:io';

import 'config.dart';
import 'log.dart';

/// Instalar el agente como servicio del sistema, sin scripts sueltos.
///
/// El objetivo es que baste con ejecutar el programa: él se instala, se
/// registra para arrancar con la máquina y se pone a trabajar.
class Servicio {
  Servicio._();

  static const nombre = 'chalona-print-agente';

  /// El ejecutable que está corriendo ahora mismo.
  static String get ejecutable => Platform.resolvedExecutable;

  /// True si el programa se está ejecutando desde el SDK (`dart run`), donde
  /// instalar un servicio apuntaría al intérprete y no al agente.
  static bool get esDesarrollo =>
      Platform.resolvedExecutable.endsWith('dart') ||
      Platform.resolvedExecutable.endsWith('dart.exe');

  static Future<void> instala(ConfigAgente config) async {
    if (esDesarrollo) {
      throw StateError(
        'Estás corriendo con `dart run`: compila primero con '
        '`dart compile exe bin/chalona_print_agente.dart -o chalona-print-agente`.',
      );
    }
    if (Platform.isWindows) return _instalaWindows();
    if (Platform.isLinux) return _instalaSystemd();
    if (Platform.isMacOS) return _instalaLaunchd();
    throw UnsupportedError('Sistema no soportado: ${Platform.operatingSystem}');
  }

  static Future<void> desinstala() async {
    if (Platform.isWindows) {
      await _corre('schtasks', ['/delete', '/tn', nombre, '/f']);
      await _corre('schtasks', ['/delete', '/tn', '$nombre-bandeja', '/f']);
      return;
    }
    if (Platform.isLinux) {
      await _corre('systemctl', ['disable', '--now', nombre]);
      final u = File('/etc/systemd/system/$nombre.service');
      if (u.existsSync()) u.deleteSync();
      await _corre('systemctl', ['daemon-reload']);
      return;
    }
    if (Platform.isMacOS) {
      await _corre('launchctl', ['unload', _rutaPlist]);
      final p = File(_rutaPlist);
      if (p.existsSync()) p.deleteSync();
    }
  }

  // ------------------------------------------------------------------ Windows

  /// En Windows el agente queda como **tarea programada al arranque, con la
  /// cuenta SYSTEM**, no como servicio del Administrador de servicios.
  ///
  /// La diferencia importa poco en la práctica —arranca con la máquina, sin que
  /// nadie inicie sesión, y se reinicia si se cae— y evita el problema real:
  /// un servicio de verdad tiene que atender llamadas del sistema desde otro
  /// hilo, y el modelo de un solo hilo de Dart no puede sostener eso sin
  /// arriesgarse a caídas raras en la máquina de un cliente.
  ///
  /// El icono de la bandeja va aparte, al iniciar sesión el usuario: un proceso
  /// en la sesión 0, que es donde viven los servicios, **no puede pintar
  /// iconos** en la barra de nadie.
  static Future<void> _instalaWindows() async {
    await _corre('schtasks', [
      '/create', '/tn', nombre,
      '/tr', '"$ejecutable" correr',
      '/sc', 'onstart',
      '/ru', 'SYSTEM',
      '/rl', 'HIGHEST',
      '/f',
    ]);
    await _corre('schtasks', [
      '/create', '/tn', '$nombre-bandeja',
      '/tr', '"$ejecutable" bandeja',
      '/sc', 'onlogon',
      '/rl', 'LIMITED',
      '/f',
    ]);
    await _corre('schtasks', ['/run', '/tn', nombre]);
    log.info('servicio', 'instalado como tarea al arranque y bandeja al inicio de sesión');
  }

  // ------------------------------------------------------------------- Linux

  static Future<void> _instalaSystemd() async {
    final unidad = '''
[Unit]
Description=Agente de impresión chalona-print
After=network-online.target cups.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$ejecutable correr
Restart=always
RestartSec=5
# El agente habla con el spooler y con el hub; no necesita nada más.
NoNewPrivileges=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
''';
    File('/etc/systemd/system/$nombre.service').writeAsStringSync(unidad);
    await _corre('systemctl', ['daemon-reload']);
    await _corre('systemctl', ['enable', '--now', nombre]);
    log.info('servicio', 'instalado en systemd como $nombre');
  }

  // ------------------------------------------------------------------- macOS

  static const _rutaPlist = '/Library/LaunchDaemons/com.chalona.print.agente.plist';

  static Future<void> _instalaLaunchd() async {
    final plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.chalona.print.agente</string>
  <key>ProgramArguments</key><array>
    <string>$ejecutable</string><string>correr</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
''';
    File(_rutaPlist).writeAsStringSync(plist);
    await _corre('launchctl', ['load', '-w', _rutaPlist]);
    log.info('servicio', 'instalado en launchd');
  }

  static Future<void> _corre(String bin, List<String> args) async {
    final r = await Process.run(bin, args);
    if (r.exitCode != 0) {
      throw StateError(
        '$bin ${args.first} falló (${r.exitCode}): ${r.stderr.toString().trim()}',
      );
    }
  }
}
