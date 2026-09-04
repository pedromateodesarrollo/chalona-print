import '../seguridad.dart';
import '../ws/agentes_ws.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Alta, baja y registro de agentes.
///
/// Para instalar un agente hacen falta **dos datos y ninguno más**: la URL del
/// hub y una llave de API. El agente se registra solo con esa llave y recibe
/// una credencial propia, que es la que usa desde ese momento. El humano no
/// teclea nada más ni tiene que entrar al manager primero.
void registraRutasAgentes(Servidor s, HubAgentes hub) {
  s.ruta('GET', '/v1/agentes', (p) async {
    final r = await p.bd.filas(
      '''select a.id, a.nombre, a.huella, a.conectado, a.version, a.plataforma,
                a.ultima_conexion, a.ultima_desconexion, a.creado,
                a.dominio, d.nombre as dominio_nombre,
                count(i.id)::int as impresoras
           from print.agente a
           left join print.dominio d on d.id = a.dominio
           left join print.impresora i on i.agente = a.id
          where a.org = @o and (@dom::bigint is null or a.dominio = @dom)
          group by a.id, d.nombre
          order by a.nombre''',
      {'o': p.s.org, 'dom': p.s.dominio},
    );
    // `conectado` en la base puede mentir si el hub se reinició de golpe; lo
    // que manda es si hay socket vivo ahora mismo.
    for (final a in r) {
      a['conectado'] = hub.estaConectado(a['id'] as int);
    }
    return Respuesta.ok({'agentes': r});
  }, acceso: Acceso.cualquiera);

  /// El agente se da de alta con la llave de API y recibe su credencial.
  ///
  /// Es idempotente por `huella`: reinstalar el servicio en la misma
  /// computadora renueva la credencial de ese agente en vez de crear uno nuevo,
  /// que es lo que llenaría la lista de fantasmas al cabo de un año.
  s.ruta('POST', '/v1/agentes/registrar', (p) async {
    if (!p.s.puede('agentes:registrar')) {
      return Respuesta.falla(403, 'sin_permiso', 'La llave no puede registrar agentes');
    }
    final huella = p.texto('huella');
    if (huella.isEmpty) {
      return Respuesta.falla(400, 'falta_huella',
          'Manda una huella estable de la máquina (el agente la genera sola)');
    }
    final nombre = p.texto('nombre', porDefecto: 'Computadora sin nombre');
    final secreto = Seguridad.token();

    // El agente hereda el dominio de la llave con la que se instaló. Si la
    // llave alcanza toda la organización, se acepta el que pida el instalador
    // y, si no pide ninguno, cae en «General».
    final dominio = await dominioDeLaPeticion(p);

    final a = await p.bd.fila(
      '''insert into print.agente (org, nombre, huella, credencial_hash, plataforma, version, dominio)
         values (@o, @n, @hu, @h, @p, @v, @dom)
         -- El `where` repite el predicado del índice parcial: sin él, Postgres
         -- no sabe qué índice usar para resolver el conflicto (42P10).
         on conflict (org, huella) where huella is not null do update set
           credencial_hash = excluded.credencial_hash,
           plataforma = excluded.plataforma,
           version = excluded.version,
           dominio = excluded.dominio
         returning id, nombre, dominio, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        'hu': huella,
        'h': Seguridad.hashToken(secreto),
        'p': p.texto('plataforma'),
        'v': p.texto('version'),
        'dom': dominio,
      },
    );
    // Las impresoras heredan el dominio del agente; al reinstalarlo en otro
    // dominio hay que arrastrarlas, o quedarían visibles donde ya no toca.
    await p.bd.ejecuta(
      'update print.impresora set dominio = @dom where agente = @a',
      {'dom': dominio, 'a': a!['id']},
    );
    return Respuesta.ok({
      'agente': a['id'],
      'nombre': a['nombre'],
      'dominio': a['dominio'],
      // Única vez que se ve. Solo se guardó el hash.
      'credencial': 'cag_${a['id']}_$secreto',
    });
  }, acceso: Acceso.cualquiera);

  s.ruta('PATCH', '/v1/agentes/:id', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) return Respuesta.falla(400, 'falta_nombre', '');
    final a = await p.bd.fila(
      '''update print.agente set nombre = @n
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)
        returning id, nombre''',
      {'n': nombre, 'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    return a == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(a);
  });

  /// Revocar la credencial sin borrar el agente: la computadora se queda fuera
  /// pero el historial de sus trabajos sigue en pie.
  s.ruta('POST', '/v1/agentes/:id/revocar', (p) async {
    final a = await p.bd.fila(
      '''update print.agente set credencial_hash = null, conectado = false
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)
        returning id''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    if (a == null) return Respuesta.falla(404, 'no_encontrado', '');
    await hub.desconecta(p.enteroParam('id'));
    return Respuesta.ok({'ok': true});
  }, acceso: Acceso.admin);

  s.ruta('DELETE', '/v1/agentes/:id', (p) async {
    await hub.desconecta(p.enteroParam('id'));
    await p.bd.ejecuta(
      '''delete from print.agente
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}
