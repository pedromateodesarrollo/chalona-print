import 'dart:convert';
import 'dart:io';

import 'cliente.dart';
import 'config.dart';
import 'driver.dart';
import 'log.dart';
import 'registro.dart';

/// El panel local: lo que se abre al hacer clic en el icono de la bandeja.
///
/// Es una página servida por el propio agente en 127.0.0.1. Se eligió así en
/// vez de una ventana nativa por una razón práctica: la misma pantalla sirve
/// en Windows, Linux y macOS, se ve en el navegador que ya tiene la máquina y
/// no arrastra un kit gráfico al instalador.
///
/// **Escucha solo en loopback.** Nadie de la red puede abrirlo, y por eso
/// puede enseñar el estado sin pedir clave a quien ya está sentado ahí.
class Panel {
  Panel(this.config, this.cliente);

  final ConfigAgente config;

  /// Null mientras el agente no está configurado: entonces el panel es el
  /// asistente de instalación.
  Cliente? cliente;

  HttpServer? _http;

  String get url => 'http://127.0.0.1:${config.puertoPanel}';

  Future<void> arranca() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, config.puertoPanel);
    log.info('panel', 'panel local en $url');
    _http!.listen(_atiende);
  }

  Future<void> detiene() async => _http?.close(force: true);

  Future<void> _atiende(HttpRequest pet) async {
    try {
      switch (pet.uri.path) {
        case '/':
          await _html(pet, config.configurado ? _paginaEstado() : _paginaInstalar());
        case '/estado.json':
          await _json(pet, _estado());
        case '/configurar':
          await _configura(pet);
        case '/probar':
          await _prueba(pet);
        default:
          pet.response.statusCode = 404;
          await pet.response.close();
      }
    } catch (e) {
      log.error('panel', '$e');
      pet.response.statusCode = 500;
      await pet.response.close();
    }
  }

  Map<String, Object?> _estado() => {
    'configurado': config.configurado,
    'hub': config.hub,
    'agente': config.agente,
    'nombre': config.nombre,
    'version': agenteVersion,
    'driver': cliente?.driver.nombre ?? config.driver,
    'conectado': cliente?.conectado ?? false,
    'conectado_desde': cliente?.conectadoDesde?.toIso8601String(),
    'impresos': cliente?.impresos ?? 0,
    'fallidos': cliente?.fallidos ?? 0,
    'ultimo_error': cliente?.ultimoError ?? '',
    'impresoras':
        (cliente?.ultimoInventario ?? const <ImpresoraLocal>[])
            .map((i) => i.aJson())
            .toList(),
    'log': log.ultimas.reversed.take(50).toList(),
  };

  /// Alta desde el asistente: URL del hub y llave de API. Nada más.
  Future<void> _configura(HttpRequest pet) async {
    if (pet.method != 'POST') {
      pet.response.statusCode = 405;
      await pet.response.close();
      return;
    }
    final cuerpo = jsonDecode(await utf8.decoder.bind(pet).join());
    final hub = (cuerpo['hub'] ?? '').toString().trim();
    final llave = (cuerpo['llave'] ?? '').toString().trim();
    final nombre = (cuerpo['nombre'] ?? '').toString().trim();
    try {
      await registraAgente(config, hub: hub, llave: llave, nombre: nombre);
      await _json(pet, {'ok': true, 'agente': config.agente});
    } catch (e) {
      await _json(pet, {'ok': false, 'mensaje': '$e'}, estado: 400);
    }
  }

  /// Impresión de prueba desde el panel. Es la primera pregunta de cualquier
  /// instalación: «¿esto imprime?».
  Future<void> _prueba(HttpRequest pet) async {
    final cuerpo = jsonDecode(await utf8.decoder.bind(pet).join());
    final impresora = (cuerpo['impresora'] ?? '').toString();
    final c = cliente;
    if (c == null) {
      await _json(pet, {'ok': false, 'mensaje': 'El agente no está configurado'}, estado: 400);
      return;
    }
    try {
      await c.driver.imprime(
        TrabajoLocal(
          id: -1,
          impresora: impresora,
          formato: 'texto',
          nombre: 'Prueba de chalona-print',
          contenido: utf8.encode(
            'chalona-print\nPrueba desde el panel local\n'
            '${DateTime.now()}\n\n\n',
          ),
        ),
      );
      await _json(pet, {'ok': true});
    } catch (e) {
      await _json(pet, {'ok': false, 'mensaje': '$e'}, estado: 500);
    }
  }

  Future<void> _json(HttpRequest pet, Object cuerpo, {int estado = 200}) async {
    pet.response
      ..statusCode = estado
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(cuerpo));
    await pet.response.close();
  }

  Future<void> _html(HttpRequest pet, String cuerpo) async {
    pet.response
      ..headers.contentType = ContentType.html
      ..write(cuerpo);
    await pet.response.close();
  }

  // ------------------------------------------------------------- las páginas

  static const _estilo = '''
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
         margin: 0; padding: 24px; max-width: 820px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { opacity: .65; margin-bottom: 20px; }
  .tarjeta { border: 1px solid rgba(128,128,128,.35); border-radius: 10px;
             padding: 16px; margin-bottom: 14px; }
  .fila { display: flex; justify-content: space-between; gap: 12px;
          padding: 7px 0; border-bottom: 1px solid rgba(128,128,128,.15); }
  .fila:last-child { border: 0; }
  .punto { display: inline-block; width: 9px; height: 9px; border-radius: 50%;
           margin-right: 7px; }
  .ok { background: #16a34a; } .mal { background: #dc2626; } .tibio { background: #ca8a04; }
  label { display: block; margin: 12px 0 4px; font-weight: 600; }
  input { width: 100%; padding: 9px 11px; border-radius: 7px;
          border: 1px solid rgba(128,128,128,.5); background: transparent;
          color: inherit; font: inherit; }
  button { margin-top: 16px; padding: 9px 16px; border-radius: 7px; border: 0;
           background: #2563eb; color: #fff; font: inherit; cursor: pointer; }
  button.suave { background: transparent; color: inherit;
                 border: 1px solid rgba(128,128,128,.5); margin: 0; padding: 5px 10px; }
  pre { background: rgba(128,128,128,.12); padding: 12px; border-radius: 8px;
        overflow-x: auto; font-size: 12px; max-height: 260px; }
  .aviso { color: #dc2626; }
  ''';

  String _paginaInstalar() => '''
<!doctype html><meta charset="utf-8"><title>Instalar chalona-print</title>
<style>$_estilo</style>
<h1>Agente de impresión</h1>
<p class="sub">Esta computadora todavía no está conectada a un hub.</p>
<div class="tarjeta">
  <label>Dirección del hub</label>
  <input id="hub" placeholder="https://print.chalonasoft.com">
  <label>Llave de API</label>
  <input id="llave" placeholder="cpk_...">
  <label>Nombre de esta computadora</label>
  <input id="nombre" value="${Platform.localHostname}">
  <button onclick="guardar()">Conectar</button>
  <p id="msg"></p>
</div>
<script>
async function guardar() {
  const msg = document.getElementById('msg');
  msg.textContent = 'Conectando…'; msg.className = '';
  const r = await fetch('/configurar', {
    method: 'POST', headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      hub: hub.value.trim(), llave: llave.value.trim(), nombre: nombre.value.trim()
    })
  });
  const d = await r.json();
  if (d.ok) { msg.textContent = 'Listo. Agente ' + d.agente + '.'; setTimeout(() => location.reload(), 1200); }
  else { msg.textContent = d.mensaje; msg.className = 'aviso'; }
}
</script>
''';

  String _paginaEstado() => '''
<!doctype html><meta charset="utf-8"><title>chalona-print — ${config.nombre}</title>
<style>$_estilo</style>
<h1>${config.nombre}</h1>
<p class="sub">Agente de impresión · <span id="hub"></span></p>
<div class="tarjeta" id="resumen"></div>
<div class="tarjeta"><strong>Impresoras</strong><div id="impresoras"></div></div>
<div class="tarjeta"><strong>Actividad</strong><pre id="log"></pre></div>
<script>
const E = ${jsonEncode({
    'lista': 'Lista',
    'ocupada': 'Imprimiendo',
    'pausada': 'En pausa',
    'sin_papel': 'Sin papel',
    'error': 'Con error',
    'desconocida': 'Desconocida',
  })};
async function refrescar() {
  const d = await (await fetch('/estado.json')).json();
  hub.textContent = d.hub;
  resumen.innerHTML = fila('Conexión con el hub',
      punto(d.conectado ? 'ok' : 'mal') + (d.conectado ? 'Conectado' : 'Sin conexión'))
    + fila('Impresos', d.impresos) + fila('Fallidos', d.fallidos)
    + fila('Versión', d.version + ' · ' + d.driver)
    + (d.ultimo_error ? fila('Último error', '<span class="aviso">' + esc(d.ultimo_error) + '</span>') : '');
  impresoras.innerHTML = d.impresoras.length
    ? d.impresoras.map(i => fila(
        punto(i.estado === 'lista' ? 'ok' : (i.estado === 'error' || i.estado === 'sin_papel' ? 'mal' : 'tibio'))
        + esc(i.nombre),
        (E[i.estado] || i.estado)
        + ' <button class="suave" onclick="probar(\\'' + esc(i.sistema) + '\\')">Prueba</button>')).join('')
    : '<p class="sub">Ninguna. Revisa que el sistema tenga impresoras instaladas.</p>';
  log.textContent = d.log.join('\\n');
}
function fila(a, b) { return '<div class="fila"><span>' + a + '</span><span>' + b + '</span></div>'; }
function punto(c) { return '<span class="punto ' + c + '"></span>'; }
function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
async function probar(impresora) {
  const d = await (await fetch('/probar', { method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({impresora}) })).json();
  alert(d.ok ? 'Mandada a ' + impresora : 'No se pudo: ' + d.mensaje);
}
refrescar(); setInterval(refrescar, 3000);
</script>
''';
}
