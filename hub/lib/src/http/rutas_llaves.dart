import '../seguridad.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Permisos que puede llevar una llave de API. Cortos a propósito: una llave
/// que solo imprime no debería poder listar los agentes de la organización.
const permisosValidos = {
  'trabajos:escribir',
  'trabajos:leer',
  'impresoras:leer',
  'agentes:registrar',
  // Llave de administración: abre TODO el API, incluida la gestión de usuarios
  // y de otras llaves. Es para automatizar la administración desde otro
  // sistema; no se reparte a las aplicaciones que solo imprimen.
  'admin',
};

/// Llaves de API para las aplicaciones que imprimen.
///
/// Es el camino de integración de un tercero: crea una llave, la mete en su
/// ERP y no vuelve a pensar en sesiones. No caducan solas —un ERP no está para
/// renovar tokens— así que lo que hay es revocación.
void registraRutasLlaves(Servidor s) {
  s.ruta('GET', '/v1/llaves', (p) async {
    final r = await p.bd.filas(
      '''select l.id, l.nombre, l.prefijo, l.permisos, l.creado, l.ultimo_uso,
                l.revocada, l.dominio, d.nombre as dominio_nombre
           from print.llave l
           left join print.dominio d on d.id = l.dominio
          where l.org = @o and (@dom::bigint is null or l.dominio = @dom)
          order by l.id desc''',
      {'o': p.s.org, 'dom': p.s.dominio},
    );
    return Respuesta.ok({'llaves': r});
  }, acceso: Acceso.admin);

  s.ruta('POST', '/v1/llaves', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre para saber después qué la usa');
    }
    final pedidos = ((p.cuerpo['permisos'] as List?) ?? const [])
        .map((x) => x.toString())
        .toSet();
    // Por defecto lleva lo que hace falta para el caso completo: instalar un
    // agente e imprimir. Una llave más estrecha se pide explícitamente.
    final permisos = pedidos.isEmpty
        ? {'trabajos:escribir', 'impresoras:leer', 'agentes:registrar'}
        : pedidos;
    final malos = permisos.difference(permisosValidos);
    if (malos.isNotEmpty) {
      return Respuesta.falla(400, 'permiso_invalido',
          'No existe: ${malos.join(", ")}. Válidos: ${permisosValidos.join(", ")}');
    }

    // Hex, no base64url: el prefijo viaja dentro de `cpk_<prefijo>_<secreto>`
    // y un guion bajo ahí rompería el corte.
    final prefijo = Seguridad.hex(4);
    final secreto = Seguridad.token();

    // `dominio` vacío = la llave alcanza toda la organización. Con dominio,
    // queda encerrada ahí: es la que se le manda a una sucursal.
    final dominio = p.cuerpo['dominio'] == null ||
            p.cuerpo['dominio'].toString().trim().isEmpty
        ? null
        : await dominioDeLaPeticion(p);

    final l = await p.bd.fila(
      '''insert into print.llave (org, nombre, prefijo, clave_hash, permisos, dominio)
         values (@o, @n, @p, @h, @perm, @dom)
         returning id, nombre, prefijo, permisos, dominio, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        'p': prefijo,
        'h': Seguridad.hashToken(secreto),
        'perm': permisos.toList(),
        'dom': dominio,
      },
    );
    return Respuesta.creado({
      ...l!,
      // Única vez que se ve completa. Se guarda hasheada.
      'llave': 'cpk_${prefijo}_$secreto',
    });
  }, acceso: Acceso.admin);

  /// Revocar, no borrar: la fila sigue explicando qué llave mandó los trabajos
  /// de la semana pasada.
  s.ruta('DELETE', '/v1/llaves/:id', (p) async {
    await p.bd.ejecuta(
      '''update print.llave set revocada = now()
          where id = @i and org = @o and (@dom::bigint is null or dominio = @dom)''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'dom': p.s.dominio},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}
