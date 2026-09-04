import 'dart:convert';
import 'dart:io';

import 'cliente.dart';
import 'config.dart';
import 'log.dart';

/// Da de alta esta computadora en el hub usando la llave de API.
///
/// Es todo lo que hay que teclear para instalar: dirección y llave. A cambio
/// el hub devuelve una credencial propia de esta máquina, que es la que queda
/// guardada. **La llave de API no se guarda**: con ella se podría dar de alta
/// cualquier otra cosa en la organización, y no tiene por qué vivir en cada
/// computadora del almacén.
Future<void> registraAgente(
  ConfigAgente config, {
  required String hub,
  required String llave,
  String nombre = '',
}) async {
  final url = _normaliza(hub);
  if (url == null) {
    throw ArgumentError('La dirección del hub no es válida (ej: https://print.chalonasoft.com)');
  }
  if (!llave.startsWith('cpk_')) {
    throw ArgumentError('La llave de API empieza por «cpk_»; revisa lo que pegaste');
  }

  final huella = config.huella.isEmpty
      ? ConfigAgente.huellaDeLaMaquina()
      : config.huella;
  final cuerpo = jsonEncode({
    'huella': huella,
    'nombre': nombre.isEmpty ? Platform.localHostname : nombre,
    'plataforma': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'version': agenteVersion,
  });

  final cliente = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final pet = await cliente.postUrl(Uri.parse('$url/v1/agentes/registrar'));
    pet.headers
      ..set('content-type', 'application/json')
      ..set('authorization', 'Bearer $llave');
    pet.write(cuerpo);
    final res = await pet.close();
    final texto = await utf8.decoder.bind(res).join();
    final d = jsonDecode(texto);

    if (res.statusCode != 200 || d is! Map) {
      final mensaje = d is Map ? (d['mensaje'] ?? d['error']) : texto;
      throw StateError('El hub rechazó el alta (${res.statusCode}): $mensaje');
    }

    config
      ..hub = url
      ..huella = huella
      ..agente = (d['agente'] as num).toInt()
      ..nombre = d['nombre']?.toString() ?? nombre
      ..credencial = d['credencial'].toString();
    config.guarda();
    log.info('registro', 'dado de alta como agente ${config.agente} en $url');
  } finally {
    cliente.close();
  }
}

String? _normaliza(String hub) {
  var v = hub.trim();
  if (v.isEmpty) return null;
  if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
  final u = Uri.tryParse(v);
  if (u == null || u.host.isEmpty) return null;
  // Se queda con esquema, host, puerto y —si el hub vive bajo un prefijo—
  // la ruta base sin barra final. El resto del agente compone `$hub/v1/...`.
  //
  // Ojo con `Uri.replace(query: '', fragment: '')`: deja un `?#` pegado al
  // final y toda petición se va a una ruta que no existe.
  return Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: u.path.replaceAll(RegExp(r'/+\$'), ''),
  ).toString();
}
