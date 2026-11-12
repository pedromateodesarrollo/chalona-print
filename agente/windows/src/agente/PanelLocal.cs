using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace PrintServer.Agente
{
    /// <summary>
    /// El panel local del agente, en 127.0.0.1 (la misma API que <c>panel.dart</c>):
    /// <c>/estado.json</c> y <c>/probar</c> los lee la ventana; <c>/</c> es la
    /// página para el navegador.
    ///
    /// Es un servidor HTTP mínimo sobre un socket y no <c>HttpListener</c>: este
    /// pide reservar la URL en el sistema (permiso de administrador) y el panel
    /// tiene que abrir también cuando se corre el agente a mano. <b>Escucha solo
    /// en loopback</b>: nadie de la red puede abrirlo, y por eso puede enseñar el
    /// estado sin pedir clave a quien ya está sentado ahí.
    /// </summary>
    sealed class PanelLocal
    {
        readonly ConfigLocal _config;
        readonly Cliente _cliente;
        TcpListener _escucha;

        public PanelLocal(ConfigLocal config, Cliente cliente)
        {
            _config = config;
            _cliente = cliente;
        }

        public string Url => $"http://127.0.0.1:{_config.PuertoPanel}";

        public void Arranca()
        {
            _escucha = new TcpListener(IPAddress.Loopback, _config.PuertoPanel);
            _escucha.Start();
            Log.Info("panel", "panel local en " + Url);
            new Thread(Acepta) { IsBackground = true, Name = "panel" }.Start();
        }

        public void Detiene()
        {
            try { _escucha?.Stop(); } catch (Exception) { }
        }

        void Acepta()
        {
            while (true)
            {
                TcpClient c;
                try
                {
                    c = _escucha.AcceptTcpClient();
                }
                catch (Exception)
                {
                    return;
                }
                ThreadPool.QueueUserWorkItem(_ => Atiende(c));
            }
        }

        void Atiende(TcpClient c)
        {
            using (c)
            {
                try
                {
                    c.ReceiveTimeout = 5000;
                    c.SendTimeout = 30000;
                    var s = c.GetStream();
                    var (metodo, ruta, cuerpo) = LeePeticion(s);
                    if (metodo == null) return;
                    var corte = ruta.IndexOf('?');
                    if (corte >= 0) ruta = ruta.Substring(0, corte);
                    switch (ruta)
                    {
                        case "/":
                            Responde(s, 200, "text/html; charset=utf-8", _config.Configurado ? PaginaEstado() : PaginaSinConectar());
                            break;
                        case "/estado.json":
                            Responde(s, 200, "application/json; charset=utf-8", Json.Escribe(Estado()));
                            break;
                        case "/probar":
                            if (metodo != "POST")
                            {
                                Responde(s, 405, "text/plain", "");
                                break;
                            }
                            var (estado, json) = Probar(cuerpo);
                            Responde(s, estado, "application/json; charset=utf-8", Json.Escribe(json));
                            break;
                        default:
                            Responde(s, 404, "text/plain", "");
                            break;
                    }
                }
                catch (Exception e)
                {
                    Log.Error("panel", e.Message);
                }
            }
        }

        Dictionary<string, object> Estado() => new Dictionary<string, object>
        {
            ["configurado"] = _config.Configurado,
            ["hub"] = _config.Hub,
            ["agente"] = _config.Agente,
            ["nombre"] = _config.Nombre,
            ["version"] = VersionAgente.Numero,
            // `servicio` cuando lo arranca el servicio de Windows: es lo que dice que
            // sobrevive a un reinicio.
            ["modo"] = Environment.GetEnvironmentVariable("PRINT_AGENTE_MODO") ?? "primer plano",
            ["driver"] = _cliente?.Driver.Nombre ?? _config.Driver,
            ["arquitectura"] = Equipo.Arquitectura(),
            ["conectado"] = _cliente?.Conectado ?? false,
            ["conectado_desde"] = _cliente?.ConectadoDesde?.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff", CultureInfo.InvariantCulture),
            ["impresos"] = _cliente?.Impresos ?? 0,
            ["fallidos"] = _cliente?.Fallidos ?? 0,
            ["ultimo_error"] = _cliente?.UltimoError ?? "",
            ["impresoras"] = (_cliente?.UltimoInventario ?? new List<ImpresoraLocal>()).Select(i => i.AJson()).ToList(),
            // Las 50 últimas, la más nueva primero (como el panel de Dart).
            ["log"] = Log.Ultimas().AsEnumerable().Reverse().Take(50).ToList(),
        };

        /// <summary>
        /// La página de prueba desde la ventana: la misma que manda el hub con el
        /// formato <c>prueba</c>, en el protocolo de esa impresora.
        /// </summary>
        (int, Dictionary<string, object>) Probar(string cuerpo)
        {
            string impresora;
            try
            {
                impresora = Json.Texto(Json.LeeObjeto(cuerpo), "impresora");
            }
            catch (FormatException)
            {
                return (400, new Dictionary<string, object> { ["ok"] = false, ["mensaje"] = "Petición ilegible" });
            }
            if (_cliente == null)
                return (400, new Dictionary<string, object> { ["ok"] = false, ["mensaje"] = "El agente no está configurado" });
            var ficha = _cliente.UltimoInventario.FirstOrDefault(i => i.Sistema == impresora);
            try
            {
                _cliente.Protocolos.TryGetValue(impresora, out var delHub);
                var p = Prueba.Imprime(_cliente.Driver, ficha, impresora, delHub, _cliente.Config.Nombre);
                Log.Info("panel", $"prueba por {p} a «{impresora}»");
                // `lenguaje` lo lee la ventana; `protocolo`, lo nuevo.
                return (200, new Dictionary<string, object> { ["ok"] = true, ["lenguaje"] = p, ["protocolo"] = p });
            }
            catch (Exception e)
            {
                return (500, new Dictionary<string, object> { ["ok"] = false, ["mensaje"] = e.Message });
            }
        }

        // ------------------------------------------------------------------ HTTP

        static (string metodo, string ruta, string cuerpo) LeePeticion(Stream s)
        {
            var cabecera = new MemoryStream();
            var fin = 0;
            while (cabecera.Length < 32 * 1024)
            {
                var b = s.ReadByte();
                if (b < 0) return (null, null, null);
                cabecera.WriteByte((byte)b);
                fin = (b == '\r' || b == '\n') ? fin + 1 : 0;
                if (fin == 4 || (fin == 2 && cabecera.Length >= 2 && EsLfLf(cabecera))) break;
            }
            var lineas = Encoding.ASCII.GetString(cabecera.ToArray()).Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
            var primera = lineas[0].Split(' ');
            if (primera.Length < 2) return (null, null, null);
            var largo = 0;
            foreach (var l in lineas.Skip(1))
            {
                var dos = l.IndexOf(':');
                if (dos > 0 && l.Substring(0, dos).Trim().Equals("content-length", StringComparison.OrdinalIgnoreCase))
                    int.TryParse(l.Substring(dos + 1).Trim(), out largo);
            }
            largo = Math.Max(0, Math.Min(largo, 1024 * 1024));
            var cuerpo = new byte[largo];
            var leidos = 0;
            while (leidos < largo)
            {
                var n = s.Read(cuerpo, leidos, largo - leidos);
                if (n <= 0) break;
                leidos += n;
            }
            return (primera[0].ToUpperInvariant(), primera[1], Encoding.UTF8.GetString(cuerpo, 0, leidos));
        }

        static bool EsLfLf(MemoryStream m)
        {
            var b = m.GetBuffer();
            var n = (int)m.Length;
            return b[n - 1] == '\n' && b[n - 2] == '\n';
        }

        static void Responde(Stream s, int estado, string tipo, string cuerpo)
        {
            var bytes = Encoding.UTF8.GetBytes(cuerpo ?? "");
            var texto = estado == 200 ? "OK" : estado == 400 ? "Bad Request" : estado == 404 ? "Not Found"
                : estado == 405 ? "Method Not Allowed" : "Internal Server Error";
            var cab = Encoding.ASCII.GetBytes(
                $"HTTP/1.1 {estado} {texto}\r\nContent-Type: {tipo}\r\nContent-Length: {bytes.Length}\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n");
            s.Write(cab, 0, cab.Length);
            s.Write(bytes, 0, bytes.Length);
            s.Flush();
        }

        // ------------------------------------------------------------- páginas

        const string Estilo = @"
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font: 15px/1.5 system-ui, -apple-system, ""Segoe UI"", sans-serif; margin: 0; padding: 24px; max-width: 820px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { opacity: .65; margin-bottom: 20px; }
  .tarjeta { border: 1px solid rgba(128,128,128,.35); border-radius: 10px; padding: 16px; margin-bottom: 14px; }
  .fila { display: flex; justify-content: space-between; gap: 12px; padding: 7px 0; border-bottom: 1px solid rgba(128,128,128,.15); }
  .fila:last-child { border: 0; }
  .punto { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 7px; }
  .ok { background: #16a34a; } .mal { background: #dc2626; } .tibio { background: #ca8a04; }
  button.suave { background: transparent; color: inherit; border: 1px solid rgba(128,128,128,.5); margin: 0; padding: 5px 10px; border-radius: 7px; cursor: pointer; }
  pre { background: rgba(128,128,128,.12); padding: 12px; border-radius: 8px; overflow-x: auto; font-size: 12px; max-height: 260px; }
  .aviso { color: #dc2626; }
";

        /// <summary>
        /// En Windows la conexión se hace desde la ventana (print-server.exe), que
        /// la instala como servicio: aquí solo se dice eso.
        /// </summary>
        static string PaginaSinConectar() => $@"<!doctype html><meta charset=""utf-8""><title>print-server</title>
<style>{Estilo}</style>
<h1>Agente de impresión</h1>
<p class=""sub"">Esta computadora todavía no está conectada a un hub.</p>
<div class=""tarjeta"">Abre <strong>print-server</strong> desde el menú Inicio (o el programa que descargaste del hub), pon la dirección del hub y la llave y pulsa «Instalar servicio».</div>";

        string PaginaEstado()
        {
            var nombre = WebUtility.HtmlEncode(_config.Nombre);
            var estados = Json.Escribe(new Dictionary<string, object>
            {
                ["lista"] = "Lista", ["ocupada"] = "Imprimiendo", ["pausada"] = "En pausa",
                ["sin_papel"] = "Sin papel", ["error"] = "Con error", ["desconocida"] = "Desconocida",
            });
            return $@"<!doctype html><meta charset=""utf-8""><title>print-server — {nombre}</title>
<style>{Estilo}</style>
<h1>{nombre}</h1>
<p class=""sub"">Agente de impresión · <span id=""hub""></span></p>
<div class=""tarjeta"" id=""resumen""></div>
<div class=""tarjeta""><strong>Impresoras</strong><div id=""impresoras""></div></div>
<div class=""tarjeta""><strong>Actividad</strong><pre id=""log""></pre></div>
<script>
const E = {estados};
async function refrescar() {{
  const d = await (await fetch('/estado.json')).json();
  hub.textContent = d.hub;
  resumen.innerHTML = fila('Conexión con el hub',
      punto(d.conectado ? 'ok' : 'mal') + (d.conectado ? 'Conectado' : 'Sin conexión'))
    + fila('Impresos', d.impresos) + fila('Fallidos', d.fallidos)
    + fila('Versión', d.version + ' · ' + d.driver + ' · ' + d.arquitectura)
    + (d.ultimo_error ? fila('Último error', '<span class=""aviso"">' + esc(d.ultimo_error) + '</span>') : '');
  impresoras.innerHTML = d.impresoras.length
    ? d.impresoras.map(i => fila(
        punto(i.estado === 'lista' ? 'ok' : (i.estado === 'error' || i.estado === 'sin_papel' ? 'mal' : 'tibio'))
        + esc(i.nombre),
        (E[i.estado] || i.estado)
        + ' <button class=""suave"" data-i=""' + esc(i.sistema) + '"" onclick=""probar(this.dataset.i)"">Prueba</button>')).join('')
    : '<p class=""sub"">Ninguna. Revisa que el sistema tenga impresoras instaladas.</p>';
  log.textContent = d.log.join('\n');
}}
function fila(a, b) {{ return '<div class=""fila""><span>' + a + '</span><span>' + b + '</span></div>'; }}
function punto(c) {{ return '<span class=""punto ' + c + '""></span>'; }}
function esc(s) {{ return String(s).replace(/[&<>""']/g, c => ({{'&':'&amp;','<':'&lt;','>':'&gt;','""':'&quot;',""'"":'&#39;'}}[c])); }}
async function probar(impresora) {{
  const d = await (await fetch('/probar', {{ method: 'POST',
    headers: {{'content-type': 'application/json'}},
    body: JSON.stringify({{impresora}}) }})).json();
  alert(d.ok ? 'Mandada a ' + impresora : 'No se pudo: ' + d.mensaje);
}}
refrescar(); setInterval(refrescar, 3000);
</script>";
        }
    }
}
