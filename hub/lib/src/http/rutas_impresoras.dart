import '../ws/agentes_ws.dart';
import 'servidor.dart';

/// Consulta de impresoras. El inventario lo escribe el agente por WebSocket;
/// por aquí solo se lee y se le cambia el nombre visible.
void registraRutasImpresoras(Servidor s, HubAgentes hub) {
  s.ruta('GET', '/v1/impresoras', (p) async {
    if (!p.s.puede('impresoras:leer')) {
      return Respuesta.falla(403, 'sin_permiso', 'La llave no puede leer impresoras');
    }
    final agente = int.tryParse(p.consulta['agente'] ?? '');
    final r = await p.bd.filas(
      '''select i.id, i.nombre, i.sistema, i.estado, i.detalle, i.cola,
                i.predeterminada, i.formatos, i.visto,
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

  /// Solo el nombre visible y la marca de predeterminada. Todo lo demás lo
  /// dicta el sistema operativo del agente y se pisaría en el siguiente latido.
  s.ruta('PATCH', '/v1/impresoras/:id', (p) async {
    final id = p.enteroParam('id');
    final nombre = p.texto('nombre');
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
