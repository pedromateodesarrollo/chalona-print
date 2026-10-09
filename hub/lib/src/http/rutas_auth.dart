import 'dart:async';

import '../correo.dart';
import '../db.dart';
import '../limitador.dart';
import '../log.dart';
import '../seguridad.dart';
import 'rutas_org.dart';
import 'servidor.dart';

/// Cuánto vale el enlace para poner clave que genera un admin.
const vidaInvitacion = Duration(days: 7);

/// Cuánto vale el enlace de «¿Olvidaste tu clave?»: lo pide la persona y lo
/// usa en el momento, así que una hora basta y deja poca ventana a quien lea
/// su correo después.
const vidaRecuperacion = Duration(hours: 1);

/// Registro, sesión y gestión de usuarios.
///
/// El hub tiene identidad propia —usuarios y claves suyos— porque un tercero
/// que lo instale no tiene de dónde sacarlas. Quien ya tenga su propio
/// directorio usa llaves de API y no crea usuarios.
///
/// Las personas se crean con clave. Además hay un enlace de un solo uso para
/// poner una nueva (migración 0006): lo pide la persona desde la entrada si su
/// organización tiene correo de salida, o lo genera un admin.
void registraRutasAuth(Servidor s) {
  final freno = Limitador(cupo: 10, ventana: const Duration(minutes: 1));
  // «¿Olvidaste tu clave?» manda un correo a quien diga el formulario: por IP
  // frena a quien prueba correos, y por correo, a quien quiere llenarle el
  // buzón a alguien.
  final frenoRecuperarIp = Limitador(cupo: 5, ventana: const Duration(minutes: 1));
  final frenoRecuperarCorreo = Limitador(cupo: 3, ventana: const Duration(hours: 1));

  // `recuperar`: si la entrada enseña «¿Olvidaste tu clave?». Hace falta un
  // correo por donde mandar el enlace (el de alguna organización) y la URL
  // pública fijada, que es con lo que se arma (ver Config.urlPublica).
  s.ruta('GET', '/salud', (p) async {
    await p.bd.fila('select 1 as ok');
    return Respuesta.ok({
      'ok': true,
      'servicio': 'print-server',
      'recuperar': p.config.urlPublica.isNotEmpty && await hayCorreoDeSalida(p.bd),
    });
  }, acceso: Acceso.publico);

  // Alta de organización. Solo con PRINT_REGISTRO=abierto; en una instalación
  // privada se deja cerrado y los usuarios los crea el admin.
  s.ruta('POST', '/v1/auth/registro', (p) async {
    if (p.config.registro != 'abierto') {
      return Respuesta.falla(
        403,
        'registro_cerrado',
        'Este hub no acepta altas por su cuenta; pídele acceso a un administrador',
      );
    }
    if (!freno.cabe('registro:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final correo = p.texto('correo').toLowerCase();
    final clave = p.texto('clave');
    final organizacion = p.texto('organizacion');
    final problema = _revisaCredenciales(correo, clave);
    if (problema != null) return problema;
    if (organizacion.isEmpty) {
      return Respuesta.falla(400, 'falta_organizacion', 'Ponle nombre a la organización');
    }

    final existe = await p.bd.fila(
      'select id from print.usuario where correo = @c',
      {'c': correo},
    );
    if (existe != null) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }

    final creado = await p.bd.transaccion((tx) async {
      final org = await tx.fila(
        'insert into print.org (nombre, slug) values (@n, @s) returning id',
        {'n': organizacion, 's': await _slugLibre(tx, organizacion)},
      );
      return await tx.fila(
        '''insert into print.usuario (org, correo, clave_hash, nombre, rol, verificado)
           values (@o, @c, @h, @n, 'admin', false)
           returning id, org, correo, nombre, rol''',
        {
          'o': org!['id'],
          'c': correo,
          'h': Seguridad.hashClave(clave),
          'n': p.texto('nombre', porDefecto: correo.split('@').first),
        },
      );
    });

    log.info('auth', 'organización nueva: $organizacion');
    return Respuesta.creado(_conToken(creado!, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/auth/login', (p) async {
    final correo = p.texto('correo').toLowerCase();
    if (!freno.cabe('login:${p.ip}') || !freno.cabe('login:$correo')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await p.bd.fila(
      'select id, org, correo, nombre, rol, clave_hash from print.usuario where correo = @c',
      {'c': correo},
    );
    // Mismo error para «no existe» y «clave mala»: la diferencia le diría a
    // quien prueba correos cuáles están dados de alta.
    const malas = 'Correo o clave incorrectos';
    if (u == null || !Seguridad.verificaClave(p.texto('clave'), u['clave_hash'] as String)) {
      return Respuesta.falla(401, 'credenciales_invalidas', malas);
    }
    freno.olvida('login:$correo');
    await p.bd.ejecuta(
      'update print.usuario set ultimo_acceso = now() where id = @i',
      {'i': u['id']},
    );
    return Respuesta.ok(_conToken(u, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  // «¿Olvidaste tu clave?»: si el correo tiene cuenta y su organización tiene
  // correo de salida, le llega un enlace para poner una clave nueva, que vence
  // en una hora. La respuesta es siempre la misma, y todo —buscar a la
  // persona, generar el enlace, mandarlo— pasa después de contestar: ni el
  // contenido ni lo que tarda dicen si el correo tiene cuenta. La clave de
  // antes sigue valiendo hasta que se use el enlace.
  s.ruta('POST', '/v1/auth/recuperar', (p) async {
    final correo = p.texto('correo').toLowerCase();
    if (!frenoRecuperarIp.cabe('recuperar:${p.ip}') ||
        !frenoRecuperarCorreo.cabe('recuperar:$correo')) {
      return Respuesta.falla(
        429,
        'demasiados_intentos',
        'Ya pediste varios enlaces: espera un rato y revisa tu correo',
      );
    }
    if (!_correoValido(correo)) {
      return Respuesta.falla(400, 'correo_invalido', 'Revisa el correo');
    }
    unawaited(_recupera(p.bd, correo, p.config.urlPublica));
    return Respuesta.ok({'pedido': true});
  }, acceso: Acceso.publico);

  // Lo que la pantalla del enlace puede enseñar antes de que la persona ponga
  // su clave: el correo y si el enlace sirve. Nada de la organización: quien
  // tiene el enlace todavía no ha demostrado nada.
  s.ruta('GET', '/v1/auth/invitacion/:token', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await _porInvitacion(p.bd, p.params['token'] ?? '');
    if (u == null) {
      return Respuesta.falla(404, 'invitacion_invalida', 'Ese enlace no existe o ya se usó');
    }
    final vence = u['invitacion_vence'] as DateTime?;
    return Respuesta.ok({
      'correo': u['correo'],
      'vigente': vence != null && vence.isAfter(DateTime.now()),
    });
  }, acceso: Acceso.publico);

  // Pone la clave con el enlace y entra: devuelve la sesión, como el login.
  s.ruta('POST', '/v1/auth/activar', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final clave = p.texto('clave');
    final problema = _revisaClave(clave);
    if (problema != null) return problema;
    final u = await _porInvitacion(p.bd, p.texto('token'));
    final vence = u?['invitacion_vence'] as DateTime?;
    if (u == null || vence == null || vence.isBefore(DateTime.now())) {
      return Respuesta.falla(
        410,
        'invitacion_vencida',
        'El enlace venció o ya se usó. Pide otro: en la entrada, «¿Olvidaste tu clave?», o a quien administra.',
      );
    }
    // El `invitacion_hash = @t` va también en el update: dos pestañas con el
    // mismo enlace no ponen dos claves; la segunda ya no encuentra la fila.
    final hecho = await p.bd.fila(
      '''update print.usuario
            set clave_hash = @h, invitacion_hash = null, invitacion_vence = null,
                ultimo_acceso = now()
          where id = @i and invitacion_hash = @t
          returning id, org, correo, nombre, rol''',
      {
        'h': Seguridad.hashClave(clave),
        'i': u['id'],
        't': Seguridad.hashToken(p.texto('token')),
      },
    );
    if (hecho == null) {
      return Respuesta.falla(
        410,
        'invitacion_vencida',
        'El enlace venció o ya se usó. Pide otro: en la entrada, «¿Olvidaste tu clave?», o a quien administra.',
      );
    }
    freno.olvida('login:${u['correo']}');
    log.info('auth', 'clave puesta con enlace: usuario ${u['id']}');
    return Respuesta.ok(_conToken(hecho, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  s.ruta('GET', '/v1/yo', (p) async {
    final u = await p.bd.fila(
      '''select u.id, u.correo, u.nombre, u.rol, u.org, o.nombre as organizacion
           from print.usuario u join print.org o on o.id = u.org
          where u.id = @i''',
      {'i': p.s.usuario},
    );
    return u == null
        ? Respuesta.falla(404, 'no_encontrado', '')
        : Respuesta.ok(u);
  });

  s.ruta('GET', '/v1/usuarios', (p) async {
    final r = await p.bd.filas(
      '''select id, correo, nombre, rol, verificado, creado, ultimo_acceso,
                invitacion_vence
           from print.usuario where org = @o order by id''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'usuarios': r});
  }, acceso: Acceso.admin);

  // Alta dentro de la organización. Es el camino cuando el registro público
  // está cerrado, y el único que crea operadores.
  s.ruta('POST', '/v1/usuarios', (p) async {
    final correo = p.texto('correo').toLowerCase();
    final clave = p.texto('clave');
    final problema = _revisaCredenciales(correo, clave);
    if (problema != null) return problema;
    final rol = p.texto('rol', porDefecto: 'operador');
    if (rol != 'admin' && rol != 'operador') {
      return Respuesta.falla(400, 'rol_invalido', 'El rol es admin u operador');
    }
    final existe = await p.bd.fila(
      'select id from print.usuario where correo = @c',
      {'c': correo},
    );
    if (existe != null) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }
    final u = await p.bd.fila(
      '''insert into print.usuario (org, correo, clave_hash, nombre, rol, verificado)
         values (@o, @c, @h, @n, @r, true)
         returning id, correo, nombre, rol, creado''',
      {
        'o': p.s.org,
        'c': correo,
        'h': Seguridad.hashClave(clave),
        'n': p.texto('nombre', porDefecto: correo.split('@').first),
        'r': rol,
      },
    );
    return Respuesta.creado(u);
  }, acceso: Acceso.admin);

  // Un enlace para que esa persona ponga su clave ella misma (la olvidó, o se
  // le creó con una provisional). Se devuelve una sola vez —se guarda
  // hasheado— y, si la organización tiene correo de salida, además se le
  // manda; si no, lo comparte quien lo pidió. `envio` dice cuál de las dos.
  // Invalida el enlace anterior de esa persona; su clave sigue valiendo hasta
  // que lo use.
  s.ruta('POST', '/v1/usuarios/:id/invitacion', (p) async {
    final id = p.enteroParam('id');
    final u = await p.bd.fila(
      'select id, correo, nombre from print.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    if (u == null) return Respuesta.falla(404, 'no_encontrado', '');
    final token = await nuevaInvitacion(p.bd, id);
    final enlace = enlaceInvitacion(p.urlPublica, token);
    return Respuesta.ok({
      'enlace': enlace,
      'vence': DateTime.now().toUtc().add(vidaInvitacion),
      'envio': await _mandaEnlace(p, id, '${u['correo']}', '${u['nombre']}', enlace),
    });
  }, acceso: Acceso.admin);

  s.ruta('POST', '/v1/usuarios/:id/clave', (p) async {
    final id = p.enteroParam('id');
    final clave = p.texto('clave');
    // Un usuario cambia la suya; un admin cambia la de cualquiera de su
    // organización. Nadie toca la de otra organización: el `org = @o` manda.
    if (id != p.s.usuario && !p.s.esAdmin) {
      return Respuesta.falla(403, 'requiere_admin', 'Solo tu propia clave');
    }
    if (clave.length < 8) {
      return Respuesta.falla(400, 'clave_corta', 'Mínimo 8 caracteres');
    }
    final u = await p.bd.fila(
      '''update print.usuario set clave_hash = @h
          where id = @i and org = @o returning id''',
      {'h': Seguridad.hashClave(clave), 'i': id, 'o': p.s.org},
    );
    return u == null
        ? Respuesta.falla(404, 'no_encontrado', '')
        : Respuesta.ok({'ok': true});
  });

  s.ruta('DELETE', '/v1/usuarios/:id', (p) async {
    final id = p.enteroParam('id');
    if (id == p.s.usuario) {
      return Respuesta.falla(400, 'no_te_borres', 'No puedes borrar tu propio usuario');
    }
    await p.bd.ejecuta(
      'delete from print.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}

Respuesta? _revisaCredenciales(String correo, String clave) {
  if (!_correoValido(correo)) {
    return Respuesta.falla(400, 'correo_invalido', 'Revisa el correo');
  }
  return _revisaClave(clave);
}

bool _correoValido(String correo) => correo.contains('@') && correo.length >= 5;

Respuesta? _revisaClave(String clave) {
  if (clave.length < 8) {
    return Respuesta.falla(400, 'clave_corta', 'La clave necesita 8 caracteres o más');
  }
  return null;
}

/// Genera el enlace de un solo uso de [usuario] y lo deja guardado (hasheado).
/// Invalida cualquier enlace anterior de esa persona.
Future<String> nuevaInvitacion(Bd bd, int usuario, {Duration vida = vidaInvitacion}) async {
  final token = Seguridad.token();
  await bd.ejecuta(
    '''update print.usuario set invitacion_hash = @h, invitacion_vence = @v
        where id = @i''',
    {
      'h': Seguridad.hashToken(token),
      'v': DateTime.now().toUtc().add(vida),
      'i': usuario,
    },
  );
  return token;
}

/// La página del panel que pone la clave (`manager/src/componentes/Activar.vue`).
String enlaceInvitacion(String urlPublica, String token) =>
    '$urlPublica/#/activar/$token';

Future<Map<String, Object?>?> _porInvitacion(Bd bd, String token) {
  if (token.isEmpty) return Future.value(null);
  return bd.fila(
    'select id, correo, invitacion_vence from print.usuario where invitacion_hash = @h',
    {'h': Seguridad.hashToken(token)},
  );
}

/// Lo de «¿Olvidaste tu clave?» que pasa después de contestar. No lanza: lo
/// que falle queda en el log, con el id de la persona y nunca con el correo
/// que se pidió (puede ser de alguien sin cuenta).
Future<void> _recupera(Bd bd, String correo, String urlPublica) async {
  int? id;
  try {
    // Sin URL pública no hay con qué armar el enlace sin fiarse de la
    // petición (ver Config.urlPublica). La entrada no ofrece la recuperación,
    // pero la ruta contesta igual a quien la llame a mano.
    if (urlPublica.isEmpty) return;
    final u = await bd.fila(
      '''select u.id, u.correo, u.nombre, o.nombre as organizacion, o.correo as correo_org
           from print.usuario u join print.org o on o.id = u.org
          where u.correo = @c''',
      {'c': correo},
    );
    if (u == null) return;
    id = u['id'] as int;
    final c = ConfigCorreo.deJson(u['correo_org']);
    if (c == null || !c.completa) {
      log.info('auth', 'recuperación pedida: usuario $id, su organización no tiene correo de salida');
      return;
    }
    final token = await nuevaInvitacion(bd, id, vida: vidaRecuperacion);
    log.info('auth', 'recuperación pedida: usuario $id');
    final nombre = '${u['nombre']}';
    final org = '${u['organizacion']}';
    final enlace = enlaceInvitacion(urlPublica, token);
    await enviaCorreo(
      c,
      para: '${u['correo']}',
      asunto: 'Clave nueva para el panel de print-server',
      texto: 'Hola, $nombre:\n\n'
          'Pediste poner una clave nueva para el panel de print-server de $org.\n\n'
          'Ponla aquí (el enlace sirve una vez y vence en 1 hora):\n'
          '$enlace\n\n'
          'Si no lo pediste tú, ignora este correo: tu clave sigue igual.',
      html: _cuerpoHtml(
        saludo: nombre,
        parrafo: 'Pediste poner una clave nueva para el panel de '
            '<strong>print-server</strong> de ${_html(org)}.',
        boton: 'Poner mi clave nueva',
        enlace: enlace,
        pie: 'El enlace sirve una vez y vence en 1 hora. '
            'Si no lo pediste tú, ignora este correo: tu clave sigue igual.',
      ),
    );
  } on CorreoError catch (e) {
    log.aviso('correo', 'recuperación del usuario $id no salió: ${e.codigo} ${e.detalle}');
  } catch (e) {
    log.error('auth', 'recuperación${id == null ? '' : ' del usuario $id'} falló: $e');
  }
}

/// Manda por el correo de salida de la organización el enlace que generó un
/// admin. Devuelve `null` si no hay correo configurado (el enlace se comparte
/// a mano), `{enviado: true, para}` o `{enviado: false, error, detalle}`: que
/// no salga el correo no anula el enlace, sigue sirviendo.
Future<Map<String, Object?>?> _mandaEnlace(
  Peticion p,
  int id,
  String para,
  String nombre,
  String enlace,
) async {
  final o = await p.bd.fila('select nombre, correo from print.org where id = @o', {'o': p.s.org});
  final c = ConfigCorreo.deJson(o?['correo']);
  if (c == null || !c.completa) return null;
  final org = '${o?['nombre'] ?? ''}';
  final dias = vidaInvitacion.inDays;
  try {
    await enviaCorreo(
      c,
      para: para,
      asunto: 'Pon tu clave del panel de print-server de $org',
      texto: 'Hola, $nombre:\n\n'
          'Quien administra print-server en $org te mandó un enlace para que pongas '
          'tu clave del panel, donde se ven las impresoras y lo que imprimen.\n\n'
          'Ponla aquí (el enlace sirve una vez y vence en $dias días):\n'
          '$enlace\n\n'
          'Hasta que la pongas, la de antes sigue valiendo. '
          'Si no esperabas este correo, ignóralo.',
      html: _cuerpoHtml(
        saludo: nombre,
        parrafo: 'Quien administra <strong>print-server</strong> en ${_html(org)} te mandó '
            'un enlace para que pongas tu clave del panel, donde se ven las impresoras '
            'y lo que imprimen.',
        boton: 'Poner mi clave',
        enlace: enlace,
        pie: 'El enlace sirve una vez y vence en $dias días. Hasta que la pongas, la de '
            'antes sigue valiendo. Si no esperabas este correo, ignóralo.',
      ),
    );
    return {'enviado': true, 'para': para};
  } on CorreoError catch (e) {
    log.aviso('correo', 'enlace para el usuario $id no salió: ${e.codigo} ${e.detalle}');
    return {'enviado': false, 'error': e.codigo, 'detalle': e.detalle};
  }
}

/// El HTML de los dos correos: un saludo, un párrafo, el botón y la letra
/// pequeña. [parrafo] llega ya escapado (lleva su `<strong>`).
String _cuerpoHtml({
  required String saludo,
  required String parrafo,
  required String boton,
  required String enlace,
  required String pie,
}) =>
    '<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;'
    'max-width:560px;margin:0 auto;padding:16px;color:#1f2328">'
    '<p>Hola, ${_html(saludo)}:</p>'
    '<p>$parrafo</p>'
    '<p style="margin:24px 0"><a href="${_html(enlace)}" style="background:#2563eb;'
    'color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none">'
    '${_html(boton)}</a></p>'
    '<p style="font-size:13px;color:#57606a">${_html(pie)}</p></div>';

String _html(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

Map<String, Object?> _conToken(Map<String, Object?> u, String secreto) => {
  'token': Seguridad.firmaJwt(
    {'sub': u['id'], 'org': u['org'], 'rol': u['rol']},
    secreto,
  ),
  'usuario': {
    'id': u['id'],
    'correo': u['correo'],
    'nombre': u['nombre'],
    'rol': u['rol'],
    'org': u['org'],
  },
};

Future<String> _slugLibre(Bd bd, String nombre) async {
  final base = nombre
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final raiz = base.isEmpty ? 'org' : base;
  for (var i = 0; i < 50; i++) {
    final intento = i == 0 ? raiz : '$raiz-$i';
    final ocupado = await bd.fila(
      'select id from print.org where slug = @s',
      {'s': intento},
    );
    if (ocupado == null) return intento;
  }
  return '$raiz-${DateTime.now().millisecondsSinceEpoch}';
}
