import 'dart:io';

/// Log a stdout, una línea por evento, con hora en UTC.
///
/// Va a stdout porque el destino real es `journalctl` o `docker logs`: quien
/// opera esto no quiere un archivo más que rotar.
///
/// **Nunca se registra el contenido de un trabajo ni un token.** El contenido
/// puede ser una factura y los tokens son credenciales vivas; el log de un
/// servicio termina en sitios que nadie audita.
class Log {
  const Log();

  void info(String etiqueta, String mensaje) => _linea('info', etiqueta, mensaje);
  void aviso(String etiqueta, String mensaje) => _linea('aviso', etiqueta, mensaje);
  void error(String etiqueta, String mensaje) => _linea('error', etiqueta, mensaje);

  void _linea(String nivel, String etiqueta, String mensaje) {
    final t = DateTime.now().toUtc().toIso8601String();
    stdout.writeln('$t $nivel [$etiqueta] $mensaje');
  }
}

const log = Log();
