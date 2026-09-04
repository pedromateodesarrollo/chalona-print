import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'servidor.dart';

/// Los únicos nombres que se aceptan al publicar.
///
/// La carpeta de descargas se sirve tal cual y sin credencial: dejar subir un
/// nombre cualquiera sería dejar escribir en ella. Con la lista cerrada, lo
/// peor que puede pasar es que se sustituya un archivo que ya existía —que es
/// justo lo que hace publicar una versión nueva.
const _publicables = {
  'chalona-print-agente-windows-x64.exe',
  'chalona-print-agente-linux-x64',
  'chalona-print-agente-macos-arm64',
  'chalona-print-agente-macos-x64',
  'instalar.sh',
  'instalar.ps1',
};

/// Tope de una subida. El agente pesa unos 8 MB; 64 deja sitio de sobra y evita
/// que una petición mal formada llene el disco del servidor.
const int _maxSubida = 64 * 1024 * 1024;

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

/// Sube un ejecutable. Lo usan `agente/publicar.ps1` y `agente/publicar.sh`.
void registraSubidaDescargas(Servidor s) {
  s.ruta('POST', '/v1/descargas/:archivo', (p) async {
    final nombre = p.params['archivo'] ?? '';
    if (!_publicables.contains(nombre)) {
      return Respuesta.falla(
        400,
        'nombre_no_publicable',
        'Solo se publican: ${_publicables.join(", ")}',
      );
    }
    if (p.s.org != p.config.orgPublicadora) {
      return Respuesta.falla(
        403,
        'no_publicas_aqui',
        'Las descargas son del hub, no de una organización. Publica con una '
            'llave de la organización ${p.config.orgPublicadora}.',
      );
    }

    final bytes = BytesBuilder(copy: false);
    await for (final trozo in p.crudo) {
      bytes.add(trozo);
      if (bytes.length > _maxSubida) {
        return Respuesta.falla(413, 'archivo_grande',
            'El tope es ${_maxSubida ~/ (1024 * 1024)} MB');
      }
    }
    final datos = bytes.takeBytes();
    if (datos.isEmpty) {
      return Respuesta.falla(400, 'archivo_vacio', 'No llegó nada');
    }

    final dir = Directory(p.config.rutaDescargas)..createSync(recursive: true);
    final destino = File('${dir.path}${Platform.pathSeparator}$nombre');
    // Se escribe al lado y se mueve: si la subida se corta a la mitad, nadie
    // se baja medio ejecutable.
    final parcial = File('${destino.path}.parcial')..writeAsBytesSync(datos);
    parcial.renameSync(destino.path);
    if (!Platform.isWindows && !nombre.endsWith('.ps1')) {
      await Process.run('chmod', ['755', destino.path]);
    }

    final huella = sha256.convert(datos).toString();
    return Respuesta.ok({
      'archivo': nombre,
      'url': '/descargas/$nombre',
      'bytes': datos.length,
      'sha256': huella,
    });
  }, acceso: Acceso.admin, crudo: true);

  s.ruta('DELETE', '/v1/descargas/:archivo', (p) async {
    final nombre = p.params['archivo'] ?? '';
    if (!_publicables.contains(nombre)) {
      return Respuesta.falla(400, 'nombre_no_publicable', '');
    }
    if (p.s.org != p.config.orgPublicadora) {
      return Respuesta.falla(403, 'no_publicas_aqui', '');
    }
    final f = File('${p.config.rutaDescargas}${Platform.pathSeparator}$nombre');
    if (f.existsSync()) f.deleteSync();
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}

String _sistema(String nombre) {
  final n = nombre.toLowerCase();
  if (n.contains('windows') || n.endsWith('.exe')) return 'windows';
  if (n.contains('macos') || n.contains('darwin')) return 'macos';
  if (n.contains('linux')) return 'linux';
  if (n.endsWith('.sh')) return 'script';
  return 'otro';
}
