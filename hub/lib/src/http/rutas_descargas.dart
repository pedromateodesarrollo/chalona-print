import 'dart:io';

import 'package:crypto/crypto.dart';

import 'servidor.dart';

/// Descargas del agente.
///
/// El panel le dice a la gente que corra `chalona-print-agente`; si el hub no
/// sirve ese archivo, la frase no lleva a ninguna parte. Aquí se publica lo que
/// haya en la carpeta de descargas y se sirve tal cual.
///
/// Es **público** a propósito: el agente se instala en una máquina que todavía
/// no tiene credencial ninguna, y un `curl` que pidiera autenticación no
/// serviría para eso. El binario es software libre; lo que hay que guardar es
/// la llave, no el programa.
void registraRutasDescargas(Servidor s) {
  s.ruta('GET', '/v1/descargas', (p) async {
    return Respuesta.ok({'descargas': await _listado(p.config.rutaDescargas)});
  }, acceso: Acceso.publico);

  s.ruta('GET', '/descargas/:archivo', (p) async {
    final nombre = p.params['archivo'] ?? '';
    // Nombre plano y nada más: cualquier separador o `..` aquí serviría un
    // archivo de otro sitio del servidor.
    if (nombre.contains('/') || nombre.contains('\\') || nombre.contains('..')) {
      return Respuesta.falla(400, 'nombre_invalido', '');
    }
    final archivo = File(
      '${p.config.rutaDescargas}${Platform.pathSeparator}$nombre',
    );
    if (!archivo.existsSync()) {
      return Respuesta.falla(404, 'no_encontrado', 'Ese archivo no está publicado');
    }

    final res = p.crudo.response;
    res.headers
      ..contentType = nombre.endsWith('.sh')
          ? ContentType('text', 'x-shellscript', charset: 'utf-8')
          : ContentType.binary
      ..set('content-length', '${archivo.lengthSync()}')
      // El script del instalador cambia sin cambiar de nombre; los binarios
      // llevan versión en el nombre, pero tampoco se ganan nada cacheándose en
      // un navegador que los baja una vez.
      ..set('cache-control', 'no-cache');
    if (!nombre.endsWith('.sh')) {
      res.headers.set('content-disposition', 'attachment; filename="$nombre"');
    }
    if (p.crudo.method == 'HEAD') {
      await res.close();
      return Respuesta.yaEscrita();
    }
    await res.addStream(archivo.openRead());
    await res.close();
    // La respuesta ya se escribió a mano: el cuerpo del stream no cabe en
    // `Respuesta`, que es JSON.
    return Respuesta.yaEscrita();
  }, acceso: Acceso.publico);
}

/// Qué hay publicado, con su tamaño y su huella.
///
/// El sha256 se calcula al vuelo y se guarda en memoria: son cuatro archivos y
/// cambian cuando se publica una versión, no cada minuto.
final Map<String, String> _huellas = {};

Future<List<Map<String, Object?>>> _listado(String carpeta) async {
  final dir = Directory(carpeta);
  if (!dir.existsSync()) return const [];

  final salida = <Map<String, Object?>>[];
  for (final f in dir.listSync().whereType<File>()) {
    final nombre = f.uri.pathSegments.last;
    if (nombre.startsWith('.')) continue;
    final huella = _huellas.putIfAbsent(
      '$nombre:${f.lengthSync()}:${f.lastModifiedSync().millisecondsSinceEpoch}',
      () => sha256.convert(f.readAsBytesSync()).toString(),
    );
    salida.add({
      'archivo': nombre,
      'url': '/descargas/$nombre',
      'sistema': _sistema(nombre),
      'bytes': f.lengthSync(),
      'sha256': huella,
      'publicado': f.lastModifiedSync().toUtc().toIso8601String(),
    });
  }
  salida.sort((a, b) => (a['archivo'] as String).compareTo(b['archivo'] as String));
  return salida;
}

String _sistema(String nombre) {
  final n = nombre.toLowerCase();
  if (n.contains('windows') || n.endsWith('.exe')) return 'windows';
  if (n.contains('macos') || n.contains('darwin')) return 'macos';
  if (n.contains('linux')) return 'linux';
  if (n.endsWith('.sh')) return 'script';
  return 'otro';
}
