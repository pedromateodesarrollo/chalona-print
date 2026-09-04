import 'servidor.dart';

/// Dominios: cómo se reparte una organización por dentro.
///
/// Un dominio agrupa las computadoras con agente, las impresoras que traen y
/// las llaves que se entregan. La razón de existir es poder darle a una
/// sucursal —o a un cliente— una llave que instale y imprima **solo lo suyo**,
/// sin que llegue al resto de la organización.
void registraRutasDominios(Servidor s) {
  s.ruta('GET', '/v1/dominios', (p) async {
    final r = await p.bd.filas(
      '''select d.id, d.nombre, d.slug, d.descripcion, d.creado,
                count(distinct a.id)::int as agentes,
                count(distinct i.id)::int as impresoras
           from print.dominio d
           left join print.agente a on a.dominio = d.id
           left join print.impresora i on i.dominio = d.id
          where d.org = @o and (@dom::bigint is null or d.id = @dom)
          group by d.id
          order by d.nombre''',
      {'o': p.s.org, 'dom': p.s.dominio},
    );
    return Respuesta.ok({'dominios': r});
  }, acceso: Acceso.cualquiera);

  s.ruta('POST', '/v1/dominios', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre al dominio');
    }
    final slug = await slugLibre(p, p.texto('slug', porDefecto: nombre));
    final d = await p.bd.fila(
      '''insert into print.dominio (org, nombre, slug, descripcion)
         values (@o, @n, @s, @d)
         returning id, nombre, slug, descripcion, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        's': slug,
        'd': p.texto('descripcion'),
      },
    );
    return Respuesta.creado(d);
  }, acceso: Acceso.admin);

  s.ruta('PATCH', '/v1/dominios/:id', (p) async {
    final d = await p.bd.fila(
      '''update print.dominio
            set nombre = coalesce(nullif(@n, ''), nombre),
                descripcion = coalesce(nullif(@d, ''), descripcion)
          where id = @i and org = @o
        returning id, nombre, slug, descripcion''',
      {
        'n': p.texto('nombre'),
        'd': p.texto('descripcion'),
        'i': p.enteroParam('id'),
        'o': p.s.org,
      },
    );
    return d == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(d);
  }, acceso: Acceso.admin);

  /// Solo se borra un dominio vacío. Con agentes dentro, borrarlo los dejaría
  /// huérfanos —imprimiendo, pero fuera de toda regla de acceso—, que es peor
  /// que no poder borrarlo.
  s.ruta('DELETE', '/v1/dominios/:id', (p) async {
    final id = p.enteroParam('id');
    final uso = await p.bd.fila(
      '''select (select count(*) from print.agente where dominio = @i)::int as agentes,
                (select count(*) from print.llave  where dominio = @i and revocada is null)::int as llaves''',
      {'i': id},
    );
    if ((uso?['agentes'] as int? ?? 0) > 0 || (uso?['llaves'] as int? ?? 0) > 0) {
      return Respuesta.falla(
        409,
        'dominio_en_uso',
        'Tiene ${uso!['agentes']} agente(s) y ${uso['llaves']} llave(s). '
            'Muévelos o revócalos primero.',
      );
    }
    await p.bd.ejecuta(
      'delete from print.dominio where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}

/// Resuelve el dominio que toca para una petición.
///
/// Si la credencial está acotada, manda esa acotación y lo que venga en el
/// cuerpo se ignora: si no, una llave de sucursal podría pedir el dominio de
/// otra y saltarse su propio límite.
Future<int?> dominioDeLaPeticion(Peticion p, {String campo = 'dominio'}) async {
  if (p.s.dominio != null) return p.s.dominio;

  final pedido = p.cuerpo[campo];
  if (pedido == null || pedido.toString().trim().isEmpty) {
    return dominioPorDefecto(p);
  }
  final fila = await p.bd.fila(
    '''select id from print.dominio
        where org = @o and (id::text = @v or slug = lower(@v))''',
    {'o': p.s.org, 'v': pedido.toString().trim()},
  );
  return fila?['id'] as int?;
}

/// El dominio «General», que toda organización tiene. Se crea si no está: un
/// hub que venga de una versión anterior no puede quedarse sin ninguno.
Future<int?> dominioPorDefecto(Peticion p) async {
  final fila = await p.bd.fila(
    '''insert into print.dominio (org, nombre, slug)
       values (@o, 'General', 'general')
       on conflict (org, slug) do update set nombre = print.dominio.nombre
       returning id''',
    {'o': p.s.org},
  );
  return fila?['id'] as int?;
}

/// Slug único dentro de la organización.
Future<String> slugLibre(Peticion p, String texto) async {
  final base = texto
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final raiz = base.isEmpty ? 'dominio' : base;
  for (var i = 0; i < 50; i++) {
    final intento = i == 0 ? raiz : '$raiz-$i';
    final ocupado = await p.bd.fila(
      'select id from print.dominio where org = @o and slug = @s',
      {'o': p.s.org, 's': intento},
    );
    if (ocupado == null) return intento;
  }
  return '$raiz-${DateTime.now().millisecondsSinceEpoch}';
}
