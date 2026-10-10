import '../ws/agentes_ws.dart';
import 'servidor.dart';

/// Los protocolos con que se le puede hablar a una impresora (0007).
const protocolos = {'driver', 'zpl', 'epl', 'dp', 'texto'};

/// Consulta de impresoras. El inventario lo escribe el agente por WebSocket;
/// por aquí se lee y se le cambia el nombre visible y el protocolo.
void registraRutasImpresoras(Servidor s, HubAgentes hub) {
  s.ruta('GET', '/v1/impresoras', (p) async {
    if (!p.s.puede('impresoras:leer')) {
      return Respuesta.falla(403, 'sin_permiso', 'La llave no puede leer impresoras');
    }
    final agente = int.tryParse(p.consulta['agente'] ?? '');
    final r = await p.bd.filas(
      '''select i.id, i.nombre, i.sistema, i.estado, i.detalle, i.cola,
                i.predeterminada, i.formatos, i.visto, i.creado,
                i.fabricante, i.modelo, i.conexion, i.serie,
                i.protocolo, i.protocolo_auto,
                (select mp.protocolo from print.modelo_protocolo mp
                  where mp.org = i.org and mp.modelo = i.modelo) as protocolo_modelo,
                coalesce(print.protocolo(i), nullif(i.protocolo_auto, '')) as protocolo_efectivo,
                i.agente, a.nombre as agente_nombre, a.conectado as agente_conectado,
                i.dominio, d.nombre as dominio_nombre
           from print.impresora i
           join print.agente a on a.id = i.agente
           left join print.dominio d on d.id = i.dominio
          where i.org = @o
            and (@ag::bigint is null or i.agente = @ag)
            and (@dom::bigint is null or i.dominio = @dom)
          order by a.nombre, i.nombre''',
      {'o': p.s.org, 'ag': agente, 'dom': p.s.dominio},
    );
    for (final i in r) {
      i['agente_conectado'] = hub.estaConectado(i['agente'] as int);
    }
    return Respuesta.ok({'impresoras': r});
  }, acceso: Acceso.cualquiera);

  s.ruta('GET', '/v1/impresoras/:id', (p) async {
    if (!p.s.puede('impresoras:leer')) {
      return Respuesta.falla(403, 'sin_permiso', 'La llave no puede leer impresoras');
    }
    final i = await p.bd.fila(
      '''select i.*, a.nombre as agente_nombre
           from print.impresora i
           join print.agente a on a.id = i.agente
          where i.id = @i and i.org = @o
            and (@dom::bigint is null or i.dominio = @dom)''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    if (i == null) return Respuesta.falla(404, 'no_encontrado', '');
    i['agente_conectado'] = hub.estaConectado(i['agente'] as int);
    return Respuesta.ok(i);
  }, acceso: Acceso.cualquiera);

  /// El nombre visible, la marca de predeterminada y el protocolo. Todo lo
  /// demás lo dicta el sistema operativo del agente y se pisaría en el
  /// siguiente latido.
  ///
  /// `protocolo_modelo` fija el de TODAS las del modelo de esta impresora en la
  /// organización —es lo que se hace la primera vez que se ve un modelo—;
  /// `protocolo`, el de esta cola sola. `null` en cualquiera de los dos lo
  /// quita y vuelve a mandar lo de debajo.
  s.ruta('PATCH', '/v1/impresoras/:id', (p) async {
    final id = p.enteroParam('id');
    final nombre = p.texto('nombre');
    for (final clave in ['protocolo', 'protocolo_modelo']) {
      if (!p.cuerpo.containsKey(clave)) continue;
      final v = p.cuerpo[clave];
      if (v != null && !protocolos.contains(v)) {
        return Respuesta.falla(400, 'protocolo_invalido',
            '«$v» no es un protocolo: ${protocolos.join(', ')}');
      }
    }
    if (p.cuerpo.containsKey('protocolo_modelo')) {
      final i = await p.bd.fila(
        'select modelo from print.impresora where id = @i and org = @o',
        {'i': id, 'o': p.s.org},
      );
      if (i == null) return Respuesta.falla(404, 'no_encontrado', '');
      final modelo = i['modelo'] as String;
      if (modelo.isEmpty) {
        return Respuesta.falla(409, 'sin_modelo',
            'El agente no dijo el modelo de esta impresora: fija el protocolo de la cola');
      }
      final v = p.cuerpo['protocolo_modelo'];
      if (v == null) {
        await p.bd.ejecuta(
          'delete from print.modelo_protocolo where org = @o and modelo = @m',
          {'o': p.s.org, 'm': modelo},
        );
      } else {
        await p.bd.ejecuta(
          '''insert into print.modelo_protocolo (org, modelo, protocolo)
             values (@o, @m, @p)
             on conflict (org, modelo) do update
               set protocolo = excluded.protocolo, actualizado = now()''',
          {'o': p.s.org, 'm': modelo, 'p': v},
        );
      }
    }
    if (p.cuerpo.containsKey('protocolo')) {
      await p.bd.ejecuta(
        'update print.impresora set protocolo = @p where id = @i and org = @o',
        {'p': p.cuerpo['protocolo'], 'i': id, 'o': p.s.org},
      );
    }
    if (p.cuerpo.containsKey('protocolo') || p.cuerpo.containsKey('protocolo_modelo')) {
      // La prueba del panel local del agente tiene que salir igual que la del hub.
      await hub.avisaProtocolos(p.s.org);
    }
    if (p.cuerpo.containsKey('predeterminada')) {
      // Una predeterminada por agente: marcar una desmarca la anterior.
      final actual = await p.bd.fila(
        'select agente from print.impresora where id = @i and org = @o',
        {'i': id, 'o': p.s.org},
      );
      if (actual == null) return Respuesta.falla(404, 'no_encontrado', '');
      if (p.cuerpo['predeterminada'] == true) {
        await p.bd.ejecuta(
          'update print.impresora set predeterminada = false where agente = @a',
          {'a': actual['agente']},
        );
      }
      await p.bd.ejecuta(
        'update print.impresora set predeterminada = @v where id = @i',
        {'v': p.cuerpo['predeterminada'] == true, 'i': id},
      );
    }
    if (nombre.isNotEmpty) {
      await p.bd.ejecuta(
        'update print.impresora set nombre = @n where id = @i and org = @o',
        {'n': nombre, 'i': id, 'o': p.s.org},
      );
    }
    final i = await p.bd.fila(
      'select * from print.impresora where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    return i == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(i);
  });
}
