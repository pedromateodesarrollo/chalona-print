import 'dart:io';

import 'package:chalona_print_hub/hub.dart';

/// Punto de entrada del hub.
///
///   PRINT_DATABASE_URL=postgres://... chalona-print-hub
///
/// Sin argumentos: migra la base si hace falta y se pone a escuchar.
Future<void> main(List<String> args) async {
  if (args.contains('--ayuda') || args.contains('-h')) {
    stdout.writeln('chalona-print-hub\n\nVariables de entorno:\n  ${Config.ayuda}');
    return;
  }

  final Config config;
  try {
    config = Config.desdeEntorno();
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exitCode = 64; // EX_USAGE
    return;
  }

  final migraciones = Platform.environment['PRINT_MIGRACIONES']?.trim();
  final hub = await Hub.arranca(
    config,
    migraciones: (migraciones == null || migraciones.isEmpty)
        ? 'migraciones'
        : migraciones,
  );

  // Cerrar bien importa: un SIGTERM en medio de un despliegue no debe dejar
  // sockets de agentes colgando ni conexiones abiertas contra Postgres.
  for (final senal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    senal.watch().listen((_) async {
      log.info('hub', 'apagando…');
      await hub.detiene();
      exit(0);
    });
  }
}
