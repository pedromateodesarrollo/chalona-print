import 'dart:convert';
import 'dart:typed_data';

import '../cola.dart';
import '../ws/agentes_ws.dart';
import '../ws/protocolo.dart';
import 'servidor.dart';

/// Columnas que se devuelven de un trabajo. `contenido` nunca sale: puede ser
/// una factura y pesa, y quien lo mandó ya lo tiene.
const _campos = '''
  id, impresora, agente, dominio, formato, nombre, copias, opciones, estado, detalle,
  idempotencia, intentos, origen, creado, actualizado, enviado, terminado, expira''';

/// Envío y seguimiento de trabajos de impresión.
void registraRutasTrabajos(Servidor s, HubAgentes hub, Despachador cola) {
  s.ruta('POST', '/v1/trabajos', (p) async {
    if (!p.s.puede('trabajos:escribir')) {
      return Respuesta.falla(403, 'sin_permiso', 'La llave no puede enviar trabajos');
    }

    // Mandar `texto` y no decir el formato significa texto. Sin esto, un
    // `curl` de prueba llega marcado como `raw` y la impresora recibe bytes
    // crudos que no entiende.
    final formato = p.texto(
      'formato',
      porDefecto: p.cuerpo.containsKey('texto') ? 'texto' : 'raw',
    );
    if (!const ['raw', 'pdf', 'imagen', 'texto', 'prueba'].contains(formato)) {
      return Respuesta.falla(
        400,
        'formato_invalido',
        'Formatos: raw, pdf, imagen, texto, prueba',
      );
    }

    // El contenido viaja en base64 salvo el texto plano, que se manda tal cual
    // para que un `curl` a mano sea legible.
    final Uint8List contenido;
    try {
      contenido = p.cuerpo.containsKey('texto')
          ? Uint8List.fromList(utf8.encode(p.texto('texto')))
          : Uint8List.fromList(base64.decode(p.texto('contenido_b64')));
    } catch (_) {
      return Respuesta.falla(400, 'contenido_invalido', 'contenido_b64 no es base64 válido');
    }
    // `prueba` no lleva contenido: lo arma el agente según el lenguaje de la
    // impresora. Se guarda un marcador para no dejar la columna vacía.
    if (contenido.isEmpty && formato != 'prueba') {
      return Respuesta.falla(400, 'contenido_vacio', 'No hay nada que imprimir');
    }
    final aGuardar = contenido.isEmpty
        ? Uint8List.fromList(utf8.encode('prueba'))
        : contenido;
    if (contenido.length > p.config.maxTrabajoBytes) {
      return Respuesta.falla(
        413,
        'contenido_grande',
        'El tope es ${p.config.maxTrabajoBytes ~/ (1024 * 1024)} MB',
      );
    }

    final copias = p.entero('copias') ?? 1;
    if (copias < 1 || copias > 999) {
      return Respuesta.falla(400, 'copias_invalidas', 'Entre 1 y 999');
    }

    final impresora = await _buscaImpresora(p);
    if (impresora == null) {
      return Respuesta.falla(404, 'impresora_no_encontrada',
          'No hay una impresora que case con lo que mandaste');
    }
    if (impresora['ambigua'] == true) {
      return Respuesta.falla(409, 'impresora_ambigua',
          'Hay más de una impresora con ese nombre; manda el id');
    }
    if (impresora['estado'] == EstadoImpresora.ausente) {
      return Respuesta.falla(409, 'impresora_ausente',
          'El agente ya no ve esa impresora en su sistema');
    }
    // `prueba` no se comprueba contra los formatos: el agente la traduce a lo
    // que esa impresora entienda, y toda impresora entiende su propia prueba.
    if (formato != 'prueba' && !_soporta(impresora['formatos'], formato)) {
      return Respuesta.falla(415, 'formato_no_soportado',
          'Esa impresora no admite $formato');
    }

    final idempotencia = p.texto('idempotencia');
    if (idempotencia.isNotEmpty) {
      // Un reintento del cliente no imprime dos veces. Se busca antes de
      // insertar y el índice único remata la carrera entre dos peticiones
      // simultáneas con la misma llave.
      final previo = await p.bd.fila(
        'select $_campos from print.trabajo where org = @o and idempotencia = @k',
        {'o': p.s.org, 'k': idempotencia},
      );
      if (previo != null) {
        return Respuesta.ok({...previo, 'repetido': true});
      }
    }

    final Map<String, Object?>? t;
    try {
      t = await p.bd.fila(
        '''insert into print.trabajo
             (org, impresora, agente, formato, nombre, contenido, copias,
              opciones, idempotencia, origen, expira, dominio)
           values (@o, @imp, @ag, @f, @n, @c, @cop, @op::jsonb,
                   nullif(@k, ''), @orig, now() + @ttl::interval, @dom)
           returning $_campos''',
        {
          'o': p.s.org,
          'imp': impresora['id'],
          'ag': impresora['agente'],
          'f': formato,
          'n': p.texto('nombre'),
          'c': aGuardar,
          'cop': copias,
          'op': jsonEncode(p.cuerpo['opciones'] is Map ? p.cuerpo['opciones'] : {}),
          'k': idempotencia,
          'orig': p.s.llave != null ? 'llave:${p.s.llave}' : 'usuario:${p.s.usuario}',
          'ttl': '${p.config.ttlTrabajo.inMinutes} minutes',
          'dom': impresora['dominio'],
        },
      );
    } catch (e) {
      if (e.toString().contains('trabajo_idempotencia_uk')) {
        final previo = await p.bd.fila(
          'select $_campos from print.trabajo where org = @o and idempotencia = @k',
          {'o': p.s.org, 'k': idempotencia},
        );
        if (previo != null) return Respuesta.ok({...previo, 'repetido': true});
      }
      rethrow;
    }

    await p.bd.ejecuta(
      '''insert into print.evento (org, trabajo, agente, tipo, detalle)
         values (@o, @t, @a, 'en_cola', @d)''',
      {
        'o': p.s.org,
        't': t!['id'],
        'a': impresora['agente'],
        'd': '${contenido.length} bytes, $formato, $copias copia(s)',
      },
    );

    // Si el agente está conectado sale ya; si no, se queda en cola y el
    // despachador lo suelta cuando la computadora vuelva.
    final salio = await cola.despacha(t['id'] as int);
    return Respuesta.creado({
      ...t,
      'estado': salio ? EstadoTrabajo.enviado : EstadoTrabajo.enCola,
      'agente_conectado': hub.estaConectado(impresora['agente'] as int),
    });
  }, acceso: Acceso.cualquiera);

  s.ruta('GET', '/v1/trabajos', (p) async {
    final limite = (int.tryParse(p.consulta['limite'] ?? '') ?? 50).clamp(1, 200);
    final r = await p.bd.filas(
      '''select $_campos from print.trabajo
          where org = @o
            and (@dom::bigint is null or dominio = @dom)
            and (@e::text is null or estado = @e)
            and (@i::bigint is null or impresora = @i)
          order by id desc limit @l''',
      {
        'o': p.s.org,
        'dom': p.s.dominio,
        'e': p.consulta['estado'],
        'i': int.tryParse(p.consulta['impresora'] ?? ''),
        'l': limite,
      },
    );
    return Respuesta.ok({'trabajos': r});
  }, acceso: Acceso.cualquiera);

  s.ruta('GET', '/v1/trabajos/:id', (p) async {
    final t = await p.bd.fila(
      '''select $_campos from print.trabajo
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    if (t == null) return Respuesta.falla(404, 'no_encontrado', '');
    final eventos = await p.bd.filas(
      'select tipo, detalle, creado from print.evento where trabajo = @t order by id',
      {'t': t['id']},
    );
    return Respuesta.ok({...t, 'eventos': eventos});
  }, acceso: Acceso.cualquiera);

  /// Cancelar solo tiene sentido antes de que la impresora escupa el papel.
  /// Si ya está imprimiendo se avisa al agente, pero lo que salió, salió.
  s.ruta('POST', '/v1/trabajos/:id/cancelar', (p) async {
    final t = await p.bd.fila(
      '''update print.trabajo
            set estado = 'cancelado', detalle = 'Cancelado', actualizado = now(), terminado = now()
          where id = @i and org = @o and estado in ('en_cola', 'enviado')
            and (@dom::bigint is null or dominio = @dom)
        returning $_campos''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    if (t == null) {
      return Respuesta.falla(409, 'no_cancelable',
          'Ese trabajo ya no está en cola (o no existe)');
    }
    final agente = t['agente'];
    if (agente is int) {
      hub.enviar(agente, {'tipo': Protocolo.cancelar, 'trabajo': t['id']});
    }
    await p.bd.ejecuta(
      '''insert into print.evento (org, trabajo, agente, tipo, detalle)
         values (@o, @t, @a, 'cancelado', '')''',
      {'o': p.s.org, 't': t['id'], 'a': agente},
    );
    return Respuesta.ok(t);
  }, acceso: Acceso.cualquiera);
}

bool _soporta(Object? formatos, String formato) {
  if (formatos is! List || formatos.isEmpty) return true;
  return formatos.map((f) => f.toString()).contains(formato);
}

/// Acepta el id, o el nombre visible, o el nombre del sistema. Lo segundo es
/// lo que quiere quien integra: en su ERP la impresora se llama «etiquetas
/// recepción», no «7».
Future<Map<String, Object?>?> _buscaImpresora(Peticion p) async {
  final id = p.entero('impresora');
  if (id != null) {
    return p.bd.fila(
      '''select id, agente, estado, formatos, dominio from print.impresora
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)''',
      {'i': id, 'o': p.s.org, 'dom': p.s.dominio},
    );
  }
  final nombre = p.texto('impresora_nombre');
  if (nombre.isEmpty) return null;
  final r = await p.bd.filas(
    '''select id, agente, estado, formatos, dominio from print.impresora
        where org = @o
          and (@dom::bigint is null or dominio = @dom)
          and (lower(nombre) = lower(@n) or lower(sistema) = lower(@n))
        order by (estado not in ('ausente', 'sin_agente')) desc, id''',
    {'o': p.s.org, 'n': nombre, 'dom': p.s.dominio},
  );
  if (r.isEmpty) return null;
  // Dos impresoras con el mismo nombre en agentes distintos: elegir una al
  // azar imprimiría en la nave equivocada. Mejor fallar y pedir el id.
  if (r.length > 1) return {...r.first, 'ambigua': true};
  return r.first;
}
