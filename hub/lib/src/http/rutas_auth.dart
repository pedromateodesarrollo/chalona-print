
import '../db.dart';
import '../limitador.dart';
import '../log.dart';
import '../seguridad.dart';
import 'servidor.dart';

/// Registro, sesión y gestión de usuarios.
///
/// El hub tiene identidad propia —usuarios y claves suyos— porque un tercero
/// que lo instale no tiene de dónde sacarlas. Quien ya tenga su propio
/// directorio usa llaves de API y no crea usuarios.
void registraRutasAuth(Servidor s) {
  final freno = Limitador(cupo: 10, ventana: const Duration(minutes: 1));

  String ip(Peticion p) =>
      p.crudo.headers.value('x-forwarded-for')?.split(',').first.trim() ??
      p.crudo.connectionInfo?.remoteAddress.address ??
      'desconocida';

  s.ruta('GET', '/salud', (p) async {
    await p.bd.fila('select 1 as ok');
    return Respuesta.ok({'ok': true, 'servicio': 'chalona-print'});
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
    if (!freno.cabe('registro:${ip(p)}')) {
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
    if (!freno.cabe('login:${ip(p)}') || !freno.cabe('login:$correo')) {
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
      '''select id, correo, nombre, rol, verificado, creado, ultimo_acceso
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
  if (!correo.contains('@') || correo.length < 5) {
    return Respuesta.falla(400, 'correo_invalido', 'Revisa el correo');
  }
  if (clave.length < 8) {
    return Respuesta.falla(400, 'clave_corta', 'La clave necesita 8 caracteres o más');
  }
  return null;
}

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
