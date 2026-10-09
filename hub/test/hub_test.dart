@Tags(['bd'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:print_server_hub/hub.dart';
import 'package:print_server_hub/src/seguridad.dart';
import 'package:test/test.dart';

import 'smtp_falso.dart';

/// El hub de punta a punta contra un Postgres de verdad: correo de salida,
/// enlace para poner clave y «¿Olvidaste tu clave?».
///
/// Necesita `PRINT_PRUEBA_DATABASE_URL` apuntando a una base DESECHABLE: la
/// prueba borra el esquema `print` al empezar. Sin la variable, se salta.
///
///   docker run -d --name print-bd -e POSTGRES_PASSWORD=print -p 127.0.0.1:55436:5432 postgres:16-alpine
///   PRINT_PRUEBA_DATABASE_URL='postgres://postgres:print@127.0.0.1:55436/postgres?sslmode=disable' dart test
void main() {
  final url = Platform.environment['PRINT_PRUEBA_DATABASE_URL'] ?? '';
  if (url.isEmpty) {
    test('hub contra Postgres', () {}, skip: 'Falta PRINT_PRUEBA_DATABASE_URL');
    return;
  }

  const urlPublica = 'https://print.prueba.do';
  late Hub hub;
  late int org;
  late String admin; // JWT de una persona administradora
  late String operador; // JWT de una persona que no administra

  Map<String, String> entorno({bool conUrl = true}) => {
    'PRINT_DATABASE_URL': url,
    'PRINT_PUERTO': '0',
    'PRINT_MANAGER': '/no/existe',
    'PRINT_DESCARGAS': '/no/existe',
    'PRINT_SECRETO_JWT': 'secreto-de-prueba',
    if (conUrl) 'PRINT_URL_PUBLICA': '$urlPublica/',
  };

  Future<(int, Map<String, dynamic>)> pide(
    String metodo,
    String ruta, {
    Object? json,
    String? token,
    Hub? en,
  }) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(metodo, Uri.parse('http://127.0.0.1:${(en ?? hub).puerto}$ruta'));
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      if (json != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(json));
      }
      final res = await r.close();
      final texto = await utf8.decodeStream(res);
      final d = texto.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(texto) as Map);
      return (res.statusCode, d);
    } finally {
      c.close();
    }
  }

  /// Da de alta a una persona con la clave `clave-de-prueba` y devuelve su id.
  Future<int> alta(String correo, String rol) async {
    final f = await hub.bd.fila(
      '''insert into print.usuario (org, correo, clave_hash, nombre, rol, verificado)
         values (@o, @c, @h, @n, @r, true) returning id''',
      {
        'o': org,
        'c': correo,
        'h': Seguridad.hashClave('clave-de-prueba', iteraciones: 1000),
        'n': correo.split('@').first,
        'r': rol,
      },
    );
    return f!['id'] as int;
  }

  Future<String> entra(String correo, [String clave = 'clave-de-prueba']) async {
    final (st, d) = await pide('POST', '/v1/auth/login', json: {'correo': correo, 'clave': clave});
    expect(st, 200, reason: '$d');
    return d['token'] as String;
  }

  Future<void> correoDeSalida(SmtpFalso smtp) async {
    final (st, d) = await pide('PUT', '/v1/org/correo',
        json: {'host': '127.0.0.1', 'puerto': smtp.puerto, 'seguridad': 'ninguna', 'remitente': 'avisos@prueba.do'},
        token: admin);
    expect(st, 200, reason: '$d');
  }

  Future<void> sinCorreoDeSalida() => pide('PUT', '/v1/org/correo', json: {'quitar': true}, token: admin);

  // El correo de «¿Olvidaste tu clave?» sale después de contestar: se espera
  // a que llegue.
  Future<String> esperaCorreo(SmtpFalso smtp, int antes) async {
    for (var i = 0; i < 60 && smtp.mensajes.length == antes; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(smtp.mensajes.length, antes + 1, reason: 'no llegó el correo');
    return SmtpFalso.parte(smtp.mensajes.last, 'text/plain');
  }

  setUpAll(() async {
    final bd = await Bd.abrir(url);
    await bd.ejecuta('drop schema if exists print cascade');
    await bd.cerrar();
    hub = await Hub.arranca(Config.desdeEntorno(entorno()));
    org = (await hub.bd.fila(
      "insert into print.org (nombre, slug) values ('Prueba', 'prueba') returning id",
    ))!['id'] as int;
    await alta('admin@prueba.do', 'admin');
    await alta('opera@prueba.do', 'operador');
    admin = await entra('admin@prueba.do');
    operador = await entra('opera@prueba.do');
  });

  tearDownAll(() => hub.detiene());

  test('correo de salida: solo admin, la clave no vuelve, sin clave se queda la de antes, quitar', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      var (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(st, 200, reason: '$d');
      expect(d, {'configurado': false});

      final config = {
        'host': '127.0.0.1',
        'puerto': smtp.puerto,
        'seguridad': 'ninguna',
        'remitente': 'Avisos@Prueba.do',
        'usuario': 'avisos',
        'clave': 'secreto-smtp',
        'nombre': 'print-server de Prueba',
      };
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'host': 'smtp mal'}, token: admin);
      expect((st, d['error']), (400, 'host_invalido'));
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'seguridad': 'ssl3'}, token: admin);
      expect(d['error'], 'seguridad_invalida');
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'remitente': 'avisos'}, token: admin);
      expect(d['error'], 'remitente_invalido');
      (st, _) = await pide('PUT', '/v1/org/correo', json: config, token: operador);
      expect(st, 403);
      (st, _) = await pide('GET', '/v1/org/correo', token: operador);
      expect(st, 403);

      (st, d) = await pide('PUT', '/v1/org/correo', json: config, token: admin);
      expect(st, 200, reason: '$d');
      expect(d['remitente'], 'avisos@prueba.do');
      expect(d['clave_puesta'], isTrue);
      expect(d['configurado'], isTrue);
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));

      // Guardar sin clave (el panel no la tiene) deja la que estaba.
      (st, d) = await pide('PUT', '/v1/org/correo',
          json: {...config, 'clave': '', 'nombre': 'Avisos de Prueba'}, token: admin);
      expect(d['clave_puesta'], isTrue);
      (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(d['nombre'], 'Avisos de Prueba');
      expect(d.containsKey('clave'), isFalse);
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));

      // La prueba va a quien la pide, y autentica con la clave guardada.
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['para'], 'admin@prueba.do');
      expect(smtp.ordenes, contains('RCPT TO:<admin@prueba.do>'));
      final auth = smtp.ordenes.lastWhere((o) => o.startsWith('AUTH PLAIN '));
      expect(utf8.decode(base64.decode(auth.substring(11))), '\u0000avisos\u0000secreto-smtp');

      // Si el servidor la rechaza, la prueba lo dice.
      smtp.rechazaAuth = true;
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: admin);
      expect((st, d['error']), (502, 'correo_autenticacion'));

      (st, d) = await pide('PUT', '/v1/org/correo', json: {'quitar': true}, token: admin);
      expect(st, 200, reason: '$d');
      expect(d, {'configurado': false});
      (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(d['configurado'], isFalse);
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: admin);
      expect(d['error'], 'correo_sin_configurar');
    } finally {
      await sinCorreoDeSalida();
      await smtp.cierra();
    }
  });

  test('enlace de un admin: para compartir sin correo, por correo con él, y pone la clave', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      final id = await alta('enlace@prueba.do', 'operador');
      var (st, d) = await pide('POST', '/v1/usuarios/$id/invitacion', token: operador);
      expect(st, 403);

      // Sin correo de salida: el enlace, para que lo comparta quien lo pidió.
      (st, d) = await pide('POST', '/v1/usuarios/$id/invitacion', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['envio'], isNull);
      expect(d['enlace'], startsWith('$urlPublica/#/activar/'));
      final primero = (d['enlace'] as String).split('/').last;

      await correoDeSalida(smtp);
      (st, d) = await pide('POST', '/v1/usuarios/$id/invitacion', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['envio'], {'enviado': true, 'para': 'enlace@prueba.do'});
      final enlace = d['enlace'] as String;
      final token = enlace.split('/').last;
      expect(SmtpFalso.parte(smtp.mensajes.last, 'text/plain'), contains(enlace));
      expect(SmtpFalso.parte(smtp.mensajes.last, 'text/html'), contains(enlace));

      // Uno nuevo invalida el de antes.
      (st, d) = await pide('GET', '/v1/auth/invitacion/$primero');
      expect((st, d['error']), (404, 'invitacion_invalida'));
      (st, d) = await pide('GET', '/v1/auth/invitacion/$token');
      expect(st, 200, reason: '$d');
      expect(d, {'correo': 'enlace@prueba.do', 'vigente': true});

      (st, d) = await pide('GET', '/v1/usuarios', token: admin);
      final fila = (d['usuarios'] as List).firstWhere((u) => u['id'] == id);
      expect(fila['invitacion_vence'], isNotNull);

      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'corta'});
      expect((st, d['error']), (400, 'clave_corta'));
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'clave-puesta-por-mi'});
      expect(st, 200, reason: '$d');
      expect(d['usuario']['correo'], 'enlace@prueba.do');
      expect(d['token'], isNotEmpty);
      await entra('enlace@prueba.do', 'clave-puesta-por-mi');

      // Un solo uso.
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'otra-clave-mas'});
      expect((st, d['error']), (410, 'invitacion_vencida'));
      (st, d) = await pide('GET', '/v1/usuarios', token: admin);
      expect((d['usuarios'] as List).firstWhere((u) => u['id'] == id)['invitacion_vence'], isNull);
    } finally {
      await sinCorreoDeSalida();
      await smtp.cierra();
    }
  });

  test('recuperar la clave: solo con correo de salida, sin delatar cuentas, y el enlace la cambia', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      await alta('mira@prueba.do', 'operador');
      var (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isFalse);

      // Sin correo de salida no sale nada, y la respuesta es la de siempre.
      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'mira@prueba.do'});
      expect(st, 200, reason: '$d');
      expect(d, {'pedido': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(smtp.mensajes, isEmpty);

      await correoDeSalida(smtp);
      (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isTrue);

      // Un correo sin cuenta: misma respuesta, ningún correo.
      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'nadie@prueba.do'});
      expect(st, 200, reason: '$d');
      expect(d, {'pedido': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(smtp.mensajes, isEmpty);

      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'MIRA@prueba.do'});
      expect(st, 200, reason: '$d');
      expect(d, {'pedido': true});
      final texto = await esperaCorreo(smtp, 0);
      expect(smtp.ordenes, contains('RCPT TO:<mira@prueba.do>'));
      expect(smtp.mensajes.last, contains('Subject: Clave nueva para el panel de print-server'));
      expect(texto, contains('vence en 1 hora'));
      expect(texto, contains('Si no lo pediste tú, ignora este correo: tu clave sigue igual.'));
      final token = RegExp('${RegExp.escape(urlPublica)}/#/activar/(\\S+)').firstMatch(texto)!.group(1)!;

      // Hasta que se use el enlace, la clave de antes sigue valiendo.
      await entra('mira@prueba.do');
      final vence = await hub.bd.fila(
        '''select invitacion_vence between now() + interval '59 minutes' and now() + interval '61 minutes' as hora
             from print.usuario where correo = 'mira@prueba.do' ''',
      );
      expect(vence!['hora'], isTrue, reason: 'el enlace de recuperación vence en una hora');
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'clave-nueva-de-mira'});
      expect(st, 200, reason: '$d');
      expect(d['usuario']['correo'], 'mira@prueba.do');
      (st, _) = await pide('POST', '/v1/auth/login', json: {'correo': 'mira@prueba.do', 'clave': 'clave-de-prueba'});
      expect(st, 401);
      await entra('mira@prueba.do', 'clave-nueva-de-mira');
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'otra-clave-mas'});
      expect(st, 410);
      expect(d['mensaje'], contains('¿Olvidaste tu clave?'));

      // Frenos: tres por correo cada hora y cinco por IP cada minuto. Este es
      // el cuarto pedido de la IP y el tercero de mira.
      (st, _) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'mira@prueba.do'});
      expect(st, 200);
      await esperaCorreo(smtp, 1);
      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'mira@prueba.do'});
      expect((st, d['error']), (429, 'demasiados_intentos'), reason: 'cuarto del mismo correo en la hora');
      expect(d['mensaje'], isNotEmpty);
      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'admin@prueba.do'});
      expect(st, 429, reason: 'sexto de la misma IP en el minuto');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(smtp.mensajes, hasLength(2));
    } finally {
      await sinCorreoDeSalida();
      await smtp.cierra();
    }
  });

  // El enlace de recuperación se arma solo con PRINT_URL_PUBLICA: con el Host
  // de una petición sin credencial, quien la manda decide a dónde lleva el
  // correo de la organización.
  test('sin PRINT_URL_PUBLICA no se ofrece ni se manda, aunque haya correo de salida', () async {
    final smtp = await SmtpFalso.arranca();
    final otro = await Hub.arranca(Config.desdeEntorno(entorno(conUrl: false)));
    try {
      await alta('sin-url@prueba.do', 'operador');
      await correoDeSalida(smtp);
      var (st, d) = await pide('GET', '/salud', en: otro);
      expect(d['recuperar'], isFalse);
      (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isTrue);

      (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'sin-url@prueba.do'}, en: otro);
      expect(st, 200, reason: '$d');
      expect(d, {'pedido': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(smtp.mensajes, isEmpty);
      final f = await hub.bd.fila(
        "select invitacion_hash from print.usuario where correo = 'sin-url@prueba.do'",
      );
      expect(f!['invitacion_hash'], isNull);

      // El enlace que pide un admin sí sale: la petición es suya, con sesión.
      final id = (await hub.bd.fila("select id from print.usuario where correo = 'sin-url@prueba.do'"))!['id'];
      (st, d) = await pide('POST', '/v1/usuarios/$id/invitacion', token: admin, en: otro);
      expect(st, 200, reason: '$d');
      expect(d['enlace'], startsWith('http://127.0.0.1:${otro.puerto}/#/activar/'));
      expect(d['envio'], {'enviado': true, 'para': 'sin-url@prueba.do'});
    } finally {
      await sinCorreoDeSalida();
      await otro.detiene();
      await smtp.cierra();
    }
  });
}
