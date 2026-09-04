import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Lo que el agente guarda en disco.
///
/// Para instalar hacen falta dos datos: la URL del hub y una llave de API. Con
/// eso el agente se registra solo y consigue su credencial; la llave se borra
/// del archivo en cuanto sirvió, porque una llave de organización sentada en
/// cada computadora del almacén es una llave que se filtra.
class ConfigAgente {
  ConfigAgente({
    this.hub = '',
    this.credencial = '',
    this.agente = 0,
    this.nombre = '',
    this.huella = '',
    this.driver = 'auto',
    this.puertoPanel = 7717,
    this.salidaFalsa = '',
  });

  String hub;
  String credencial;
  int agente;
  String nombre;
  String huella;

  /// `auto`, `cups`, `windows` o `falso`.
  String driver;

  /// Puerto del panel local. Escucha **solo en 127.0.0.1**: es la ventana de
  /// quien está sentado en esa computadora, no un servicio de red.
  int puertoPanel;
  String salidaFalsa;

  /// True si el archivo existe pero este usuario no puede leerlo. Distingue
  /// «sin configurar» de «configurado, pero hace falta sudo», que son dos
  /// consejos distintos.
  bool ilegible = false;

  bool get configurado => hub.isNotEmpty && credencial.isNotEmpty;

  /// URL del WebSocket a partir de la del hub: http→ws, https→wss.
  /// Respeta el prefijo si el hub vive bajo una ruta (`https://host/print`).
  String get urlWs {
    final u = Uri.parse(hub);
    return Uri(
      scheme: u.scheme == 'https' ? 'wss' : 'ws',
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '${u.path}/agente/ws',
    ).toString();
  }

  // ------------------------------------------------------------------ disco

  /// Dónde vive el archivo. Cada sistema tiene su sitio para esto, y el
  /// servicio corre sin usuario interactivo: no vale `~`.
  static String rutaPorDefecto() {
    final env = Platform.environment['PRINT_AGENTE_CONFIG']?.trim();
    if (env != null && env.isNotEmpty) return env;
    if (Platform.isWindows) {
      final base = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      return '$base\\chalona-print\\agente.json';
    }
    if (Platform.isMacOS) return '/usr/local/etc/chalona-print/agente.json';
    return '/etc/chalona-print/agente.json';
  }

  /// Lee la configuración. Si no se puede —no existe, o no hay permiso—
  /// devuelve una vacía en vez de reventar.
  ///
  /// El archivo es del root porque lleva la credencial del agente. Un técnico
  /// que corra `chalona-print-agente impresoras` sin sudo no necesita esa
  /// credencial para nada, y merece la lista de impresoras y no un volcado de
  /// pila. Los comandos que sí la necesitan avisan de que hace falta sudo.
  static ConfigAgente carga([String? ruta]) {
    final f = File(ruta ?? rutaPorDefecto());
    final String texto;
    try {
      if (!f.existsSync()) return ConfigAgente();
      texto = f.readAsStringSync();
    } on FileSystemException {
      return ConfigAgente()..ilegible = true;
    }
    final d = jsonDecode(texto);
    if (d is! Map) return ConfigAgente();
    return ConfigAgente(
      hub: d['hub']?.toString() ?? '',
      credencial: d['credencial']?.toString() ?? '',
      agente: (d['agente'] as num?)?.toInt() ?? 0,
      nombre: d['nombre']?.toString() ?? '',
      huella: d['huella']?.toString() ?? '',
      driver: d['driver']?.toString() ?? 'auto',
      puertoPanel: (d['puerto_panel'] as num?)?.toInt() ?? 7717,
      salidaFalsa: d['salida_falsa']?.toString() ?? '',
    );
  }

  void guarda([String? ruta]) {
    final f = File(ruta ?? rutaPorDefecto());
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'hub': hub,
        'credencial': credencial,
        'agente': agente,
        'nombre': nombre,
        'huella': huella,
        'driver': driver,
        'puerto_panel': puertoPanel,
        'salida_falsa': salidaFalsa,
      }),
    );
    // El archivo lleva la credencial del agente. En Unix se cierra a su dueño;
    // en Windows hereda los permisos de ProgramData, que ya es solo admin para
    // escritura.
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', f.path]);
      } on ProcessException {
        // Sin chmod tampoco se cae el servicio; queda anotado y sigue.
      }
    }
  }

  /// Identidad estable de la máquina. Se prefiere el id que ya tiene el
  /// sistema para que reinstalar el agente no cree un duplicado en el hub.
  static String huellaDeLaMaquina() {
    final host = Platform.localHostname;
    final id = _idDelSistema();
    if (id != null && id.isNotEmpty) return '$host:$id';
    final r = Random.secure();
    final azar = List.generate(8, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$host:$azar';
  }

  static String? _idDelSistema() {
    try {
      if (Platform.isLinux) {
        for (final ruta in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
          final f = File(ruta);
          if (f.existsSync()) return f.readAsStringSync().trim();
        }
      } else if (Platform.isWindows) {
        final r = Process.runSync('reg', [
          'query',
          r'HKLM\SOFTWARE\Microsoft\Cryptography',
          '/v',
          'MachineGuid',
        ]);
        final m = RegExp(r'MachineGuid\s+REG_SZ\s+(\S+)')
            .firstMatch(r.stdout.toString());
        return m?.group(1);
      } else if (Platform.isMacOS) {
        final r = Process.runSync('ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice']);
        final m = RegExp(r'IOPlatformUUID"\s*=\s*"([^"]+)"')
            .firstMatch(r.stdout.toString());
        return m?.group(1);
      }
    } catch (_) {
      // Cualquier fallo aquí solo significa huella aleatoria.
    }
    return null;
  }
}
