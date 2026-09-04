import 'dart:io';
import 'dart:math';

/// Configuración del hub, toda por variable de entorno.
///
/// Un servicio que un tercero instala en su propio servidor se configura por
/// entorno: es lo que entienden systemd, Docker y cualquier PaaS. Nada de
/// archivos de configuración con rutas que adivinar.
class Config {
  Config({
    required this.urlBd,
    required this.puerto,
    required this.secretoJwt,
    required this.registro,
    required this.origenesCors,
    required this.maxTrabajoBytes,
    required this.ttlTrabajo,
    required this.rutaManager,
    required this.rutaDescargas,
    required this.secretoEfimero,
  });

  /// `postgres://usuario:clave@host:5432/base`
  final String urlBd;
  final int puerto;

  /// Clave HS256 de los JWT de sesión. Cambiarla cierra la sesión de todos.
  final String secretoJwt;

  /// `abierto` (cualquiera crea su organización), `invitacion` (solo por
  /// invitación de un admin) o `cerrado` (solo altas por API).
  final String registro;

  /// Vacío = `*`. Con contenido, solo se refleja el Origin que esté en la lista.
  final List<String> origenesCors;

  /// Tope del contenido de un trabajo. Una etiqueta ZPL pesa kilobytes; el tope
  /// existe para que un PDF de 400 páginas no tumbe el hub.
  final int maxTrabajoBytes;

  /// Cuánto vive un trabajo en cola antes de darse por vencido. Imprimir una
  /// orden de ayer porque la computadora estuvo apagada no ayuda a nadie.
  final Duration ttlTrabajo;

  /// Carpeta con el web manager compilado. Si no existe, el hub sirve solo API.
  final String rutaManager;

  /// Carpeta con los ejecutables del agente. Lo que haya ahí se publica en
  /// `/descargas/…`; si no existe, la página lo dice en vez de ofrecer un
  /// enlace muerto.
  final String rutaDescargas;

  /// True cuando el secreto JWT se generó al arrancar (no venía por entorno).
  /// Vale para desarrollo; en producción significa que un reinicio saca a todos.
  final bool secretoEfimero;

  static const _reglas = <String>[
    'PRINT_DATABASE_URL   (obligatoria)  postgres://usuario:clave@host:5432/base',
    'PRINT_PUERTO         (3070)',
    'PRINT_SECRETO_JWT    (aleatoria si falta; en producción, fíjala)',
    'PRINT_REGISTRO       (abierto|invitacion|cerrado, por defecto abierto)',
    'PRINT_CORS           (lista separada por comas; vacío = *)',
    'PRINT_MAX_TRABAJO_MB (8)',
    'PRINT_TTL_HORAS      (24)',
    'PRINT_MANAGER        (ruta al manager compilado; por defecto ./manager)',
    'PRINT_DESCARGAS      (ruta a los ejecutables del agente; por defecto ./descargas)',
  ];

  static String get ayuda => _reglas.join('\n  ');

  factory Config.desdeEntorno([Map<String, String>? entorno]) {
    final e = entorno ?? Platform.environment;
    final url = (e['PRINT_DATABASE_URL'] ?? '').trim();
    if (url.isEmpty) {
      throw ArgumentError(
        'Falta PRINT_DATABASE_URL.\n  Variables:\n  $ayuda',
      );
    }
    final secreto = (e['PRINT_SECRETO_JWT'] ?? '').trim();
    final registro = (e['PRINT_REGISTRO'] ?? 'abierto').trim().toLowerCase();
    if (!const ['abierto', 'invitacion', 'cerrado'].contains(registro)) {
      throw ArgumentError('PRINT_REGISTRO debe ser abierto, invitacion o cerrado');
    }
    return Config(
      urlBd: url,
      puerto: int.tryParse(e['PRINT_PUERTO'] ?? '') ?? 3070,
      secretoJwt: secreto.isEmpty ? _secretoAleatorio() : secreto,
      secretoEfimero: secreto.isEmpty,
      registro: registro,
      origenesCors: (e['PRINT_CORS'] ?? '')
          .split(',')
          .map((o) => o.trim())
          .where((o) => o.isNotEmpty)
          .toList(),
      maxTrabajoBytes:
          (int.tryParse(e['PRINT_MAX_TRABAJO_MB'] ?? '') ?? 8) * 1024 * 1024,
      ttlTrabajo: Duration(hours: int.tryParse(e['PRINT_TTL_HORAS'] ?? '') ?? 24),
      rutaManager: (e['PRINT_MANAGER'] ?? 'manager').trim(),
      rutaDescargas: (e['PRINT_DESCARGAS'] ?? 'descargas').trim(),
    );
  }

  static String _secretoAleatorio() {
    final r = Random.secure();
    return List.generate(48, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
