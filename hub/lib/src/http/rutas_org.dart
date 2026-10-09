import 'dart:convert';

import '../correo.dart';
import '../db.dart';
import 'servidor.dart';

/// Lo de la organización entera. Por ahora, su correo de salida (migración
/// 0005): por él salen los enlaces para poner clave, el de «¿Olvidaste tu
/// clave?» y el que genera un admin. print-server no usa el correo de ningún
/// otro sistema: cada organización pone el suyo.
///
/// Todo es de administrador, y la clave del servidor de correo no vuelve
/// nunca por la API: el panel solo sabe si está puesta.
void registraRutasOrg(Servidor s) {
  s.ruta('GET', '/v1/org/correo', (p) async {
    final c = await _correoDe(p.bd, p.s.org);
    return Respuesta.ok(c?.publico() ?? {'configurado': false});
  }, acceso: Acceso.admin);

  // La clave no vuelve nunca; si no viene, o viene vacía, se queda la que
  // estaba (el panel no la tiene para reenviarla). `{quitar: true}` lo borra.
  s.ruta('PUT', '/v1/org/correo', (p) async {
    if (p.cuerpo['quitar'] == true) {
      await p.bd.ejecuta(
        "update print.org set correo = '{}'::jsonb where id = @o",
        {'o': p.s.org},
      );
      return Respuesta.ok({'configurado': false});
    }
    final actual = await _correoDe(p.bd, p.s.org);
    final host = p.texto('host').toLowerCase();
    final puerto = p.entero('puerto') ?? 0;
    final seguridad = p.texto('seguridad', porDefecto: 'starttls');
    final remitente = p.texto('remitente').toLowerCase();
    if (host.isEmpty || host.contains(RegExp(r'[\s/:@]'))) {
      return Respuesta.falla(400, 'host_invalido', 'El servidor es un nombre como smtp.gmail.com');
    }
    if (puerto < 1 || puerto > 65535) {
      return Respuesta.falla(400, 'puerto_invalido', 'El puerto va de 1 a 65535 (suele ser 465 o 587)');
    }
    if (!ConfigCorreo.seguridades.contains(seguridad)) {
      return Respuesta.falla(400, 'seguridad_invalida', 'La seguridad es tls, starttls o ninguna');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(remitente)) {
      return Respuesta.falla(400, 'remitente_invalido', 'El remitente es una dirección de correo');
    }
    final clave = p.texto('clave').isNotEmpty ? p.texto('clave') : (actual?.clave ?? '');
    final c = ConfigCorreo(
      host: host,
      puerto: puerto,
      seguridad: seguridad,
      remitente: remitente,
      usuario: p.texto('usuario'),
      clave: clave,
      nombre: p.texto('nombre'),
    );
    await p.bd.ejecuta(
      'update print.org set correo = @c::jsonb where id = @o',
      {'c': jsonEncode(c.aJson()), 'o': p.s.org},
    );
    return Respuesta.ok(c.publico());
  }, acceso: Acceso.admin);

  // Manda un correo de prueba a quien lo pide: si llega, los enlaces también
  // llegarán. Si no, dice qué contestó el servidor.
  s.ruta('POST', '/v1/org/correo/prueba', (p) async {
    final c = await _correoDe(p.bd, p.s.org);
    if (c == null || !c.completa) {
      return Respuesta.falla(400, 'correo_sin_configurar', 'Primero guarda el correo de salida');
    }
    final yo = p.s.esUsuario
        ? await p.bd.fila('select correo from print.usuario where id = @u', {'u': p.s.usuario})
        : null;
    final para = (yo?['correo'] ?? '').toString();
    if (!para.contains('@')) {
      return Respuesta.falla(
        400,
        'sin_destinatario',
        'La prueba va al correo de quien la pide: entra con tu usuario',
      );
    }
    try {
      await enviaCorreo(
        c,
        para: para,
        asunto: 'Prueba del correo de print-server',
        texto: 'Si lees esto, el correo de salida de tu organización funciona: '
            'los enlaces para poner clave saldrán por aquí.',
      );
    } on CorreoError catch (e) {
      return Respuesta.falla(502, e.codigo, e.detalle);
    }
    return Respuesta.ok({'enviado': true, 'para': para});
  }, acceso: Acceso.admin);
}

Future<ConfigCorreo?> _correoDe(Bd bd, int org) async => ConfigCorreo.deJson(
  (await bd.fila('select correo from print.org where id = @o', {'o': org}))?['correo'],
);

/// Si alguna organización tiene correo de salida: sin él no hay por dónde
/// mandar el enlace de «¿Olvidaste tu clave?».
Future<bool> hayCorreoDeSalida(Bd bd) async {
  final filas = await bd.filas("select correo from print.org where correo <> '{}'::jsonb");
  return filas.any((f) => ConfigCorreo.deJson(f['correo'])?.completa ?? false);
}
