using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PrintServer.Agente
{
    /// <summary>
    /// El agente: mantiene el WebSocket con el hub e imprime lo que llegue
    /// (protocolo en docs/protocolo-ws.md; la misma lógica que <c>cliente.dart</c>).
    ///
    /// La conexión la abre el agente, siempre: la computadora del almacén no
    /// necesita puerto abierto, IP fija ni VPN.
    ///
    /// Los trabajos se imprimen de uno en uno, en el orden en que llegan, en un
    /// hilo aparte del que lee el socket: así un PDF largo no deja al hub sin
    /// respuesta a su ping y no se corta la conexión a mitad de una etiqueta.
    /// </summary>
    sealed class Cliente
    {
        public readonly ConfigLocal Config;
        public readonly IDriver Driver;
        readonly Hechos _hechos;

        volatile ClientWebSocket _ws;
        readonly SemaphoreSlim _envio = new SemaphoreSlim(1, 1);
        readonly CancellationTokenSource _parar = new CancellationTokenSource();
        readonly BlockingCollection<IDictionary<string, object>> _trabajos = new BlockingCollection<IDictionary<string, object>>();
        readonly object _cerrojoInventario = new object();
        int _fallosSeguidos;

        /// <summary>Último inventario, para el panel local.</summary>
        public volatile List<ImpresoraLocal> UltimoInventario = new List<ImpresoraLocal>();

        /// <summary>
        /// El protocolo que el hub tiene fijado para cada cola. Llega al conectar y
        /// cada vez que alguien lo cambia, para que la prueba del panel local salga
        /// igual que la del hub.
        /// </summary>
        public volatile Dictionary<string, string> Protocolos = new Dictionary<string, string>();

        public DateTime? ConectadoDesde;
        public volatile string UltimoError = "";
        int _impresos;
        int _fallidos;

        public int Impresos => _impresos;
        public int Fallidos => _fallidos;

        public bool Conectado => _ws?.State == WebSocketState.Open;

        public Cliente(ConfigLocal config, IDriver driver, Hechos hechos)
        {
            Config = config;
            Driver = driver;
            _hechos = hechos;
        }

        public void Corre()
        {
            var impresor = new Thread(Impresor) { IsBackground = true, Name = "impresor" };
            impresor.Start();
            // Para que el panel enseñe las impresoras desde el primer momento.
            Inventario();
            while (!_parar.IsCancellationRequested)
            {
                try
                {
                    Sesion().GetAwaiter().GetResult();
                }
                catch (Exception e)
                {
                    UltimoError = MensajeDeConexion(e);
                    Log.Aviso("cliente", "conexión caída: " + Detalle(e));
                }
                _ws = null;
                ConectadoDesde = null;
                _fallosSeguidos++;
                if (_parar.IsCancellationRequested) break;
                // Sin hub también se miran las impresoras: con la conexión caída es
                // cuando más hace falta ver si al menos ellas están.
                Inventario();
                var espera = Espera();
                Log.Info("cliente", $"reintento en {(int)espera.TotalSeconds}s");
                _parar.Token.WaitHandle.WaitOne(espera);
            }
        }

        public void Detiene()
        {
            _parar.Cancel();
            _trabajos.CompleteAdding();
            try
            {
                _ws?.Abort();
            }
            catch (Exception)
            {
            }
        }

        /// <summary>
        /// Espera creciente con algo de azar: sin el azar, veinte computadoras que
        /// perdieron la conexión a la vez vuelven todas en el mismo segundo y tumban
        /// el hub que acaba de levantarse.
        /// </summary>
        TimeSpan Espera()
        {
            var b = Math.Min(30, 1 << Math.Min(Math.Max(_fallosSeguidos - 1, 0), 5));
            return TimeSpan.FromSeconds(b) + TimeSpan.FromMilliseconds(new Random().Next(1000));
        }

        async Task Sesion()
        {
            using (var ws = new ClientWebSocket())
            {
                ws.Options.SetRequestHeader("Authorization", "Bearer " + Config.Credencial);
                ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(30);
                ws.Options.Proxy = WebRequest.DefaultWebProxy;
                using (var tiempo = CancellationTokenSource.CreateLinkedTokenSource(_parar.Token))
                {
                    tiempo.CancelAfter(TimeSpan.FromSeconds(30));
                    await ws.ConnectAsync(new Uri(Config.UrlWs), tiempo.Token).ConfigureAwait(false);
                }
                _ws = ws;

                await Envia(ws, new Dictionary<string, object>
                {
                    ["tipo"] = "hola",
                    ["protocolo"] = VersionAgente.Protocolo,
                    ["version"] = VersionAgente.Numero,
                    ["plataforma"] = Equipo.Plataforma(),
                    ["driver"] = Driver.Nombre,
                    ["impresoras"] = Inventario().Select(i => i.AJson()).ToList(),
                }).ConfigureAwait(false);

                using (var fin = CancellationTokenSource.CreateLinkedTokenSource(_parar.Token))
                {
                    var latido = Latidos(ws, fin.Token);
                    try
                    {
                        await Lee(ws).ConfigureAwait(false);
                    }
                    finally
                    {
                        fin.Cancel();
                        try { await latido.ConfigureAwait(false); } catch (Exception) { }
                    }
                }
            }
        }

        async Task Latidos(ClientWebSocket ws, CancellationToken fin)
        {
            while (!fin.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(30), fin).ConfigureAwait(false);
                if (ws.State != WebSocketState.Open) return;
                var inv = Inventario();
                await Envia(ws, new Dictionary<string, object>
                {
                    ["tipo"] = "latido",
                    ["impresoras"] = inv.Select(i => i.AJson()).ToList(),
                }).ConfigureAwait(false);
            }
        }

        async Task Lee(ClientWebSocket ws)
        {
            var buffer = new byte[64 * 1024];
            using (var mensaje = new MemoryStream())
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), _parar.Token).ConfigureAwait(false);
                    if (r.MessageType == WebSocketMessageType.Close)
                    {
                        try
                        {
                            await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None).ConfigureAwait(false);
                        }
                        catch (Exception)
                        {
                        }
                        return;
                    }
                    mensaje.Write(buffer, 0, r.Count);
                    if (!r.EndOfMessage) continue;
                    var texto = Encoding.UTF8.GetString(mensaje.GetBuffer(), 0, (int)mensaje.Length);
                    mensaje.SetLength(0);
                    IDictionary<string, object> f;
                    try
                    {
                        f = Json.Lee(texto) as IDictionary<string, object>;
                    }
                    catch (FormatException)
                    {
                        continue;
                    }
                    if (f != null) await Marco(ws, f).ConfigureAwait(false);
                }
            }
        }

        async Task Marco(ClientWebSocket ws, IDictionary<string, object> f)
        {
            switch (Json.Texto(f, "tipo"))
            {
                case "hola_ok":
                    _fallosSeguidos = 0;
                    ConectadoDesde = DateTime.Now;
                    UltimoError = "";
                    AnotaProtocolos(f);
                    Log.Info("cliente", "conectado al hub como agente " + Json.Texto(f, "agente"));
                    break;

                case "protocolos":
                    AnotaProtocolos(f);
                    break;

                case "hola_no":
                    // Reintentar no lo arregla; hace falta actualizar el agente, y eso
                    // lo tiene que ver alguien.
                    UltimoError = $"El hub no acepta este agente: {Json.Texto(f, "motivo")} " +
                                  $"(hub habla v{Json.Texto(f, "hub")}, mínima v{Json.Texto(f, "minima")}, " +
                                  $"agente v{VersionAgente.Protocolo}). Actualiza el agente.";
                    Log.Error("cliente", UltimoError);
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None).ConfigureAwait(false);
                    break;

                case "trabajo":
                    f["__ws"] = ws;
                    _trabajos.Add(f);
                    break;

                case "cancelar":
                    // Lo que ya salió, salió. Anotarlo evita imprimirlo si el hub lo
                    // reenvía por una carrera entre la cancelación y la entrega.
                    var id = Json.Numero(f, "trabajo", -1);
                    if (id >= 0) _hechos.Anota(id);
                    break;
            }
        }

        /// <summary>El hilo que imprime: un trabajo detrás de otro.</summary>
        void Impresor()
        {
            try
            {
                foreach (var f in _trabajos.GetConsumingEnumerable())
                {
                    try
                    {
                        Imprime(f["__ws"] as ClientWebSocket, f);
                    }
                    catch (Exception e)
                    {
                        Log.Error("trabajo", "fallo inesperado: " + e.Message);
                    }
                }
            }
            catch (ObjectDisposedException)
            {
            }
        }

        void Imprime(ClientWebSocket ws, IDictionary<string, object> f)
        {
            var id = Json.Numero(f, "id", -1);
            if (id < 0) return;

            if (_hechos.Contiene(id))
            {
                Log.Info("trabajo", $"{id} ya se imprimió; se confirma sin repetir");
                Ack(ws, id, "hecho", "Ya se había impreso (reenvío)");
                return;
            }

            Ack(ws, id, "imprimiendo", null);
            var impresora = Json.Texto(f, "impresora");
            try
            {
                var formato = Json.Texto(f, "formato", "raw");
                // La prueba la arma el agente, no el hub: aquí es donde se puede hablar
                // con el driver, en el protocolo que el hub tenga fijado.
                if (formato == "prueba")
                {
                    var ficha = UltimoInventario.FirstOrDefault(x => x.Sistema == impresora);
                    var p = Prueba.Imprime(Driver, ficha, impresora, Json.Texto(f, "protocolo", null), Config.Nombre, id);
                    Log.Info("trabajo", $"{id}: prueba por {p}");
                }
                else
                {
                    Driver.Imprime(new TrabajoLocal
                    {
                        Id = id,
                        Impresora = impresora,
                        Formato = formato,
                        Contenido = Convert.FromBase64String(Json.Texto(f, "contenido_b64")),
                        Nombre = Json.Texto(f, "nombre"),
                        Copias = (int)Json.Numero(f, "copias", 1),
                        Opciones = f.TryGetValue("opciones", out var o) && o is IDictionary<string, object> op
                            ? op
                            : new Dictionary<string, object>(),
                    });
                }
                // Se anota ANTES del ack: si el proceso muere entre una cosa y otra,
                // el hub reenviará y el registro dirá que ya salió.
                _hechos.Anota(id);
                Interlocked.Increment(ref _impresos);
                Ack(ws, id, "hecho", null);
                Log.Info("trabajo", $"{id} impreso en {impresora}");
            }
            catch (Exception e)
            {
                Interlocked.Increment(ref _fallidos);
                UltimoError = e.Message;
                Ack(ws, id, "fallido", e.Message);
                Log.Error("trabajo", $"{id} falló: {e.Message}");
            }
        }

        void Ack(ClientWebSocket ws, long id, string estado, string detalle)
        {
            var m = new Dictionary<string, object> { ["tipo"] = "ack", ["trabajo"] = id, ["estado"] = estado };
            if (detalle != null) m["detalle"] = detalle;
            try
            {
                Envia(ws, m).GetAwaiter().GetResult();
            }
            catch (Exception e)
            {
                // Sin conexión el hub no se entera; al volver reenvía lo que no se
                // confirmó y el registro de hechos evita que salga dos veces.
                Log.Aviso("trabajo", $"no pude confirmar {id} ({estado}): {e.Message}");
            }
        }

        async Task Envia(ClientWebSocket ws, IDictionary<string, object> m)
        {
            if (ws == null) throw new InvalidOperationException("sin conexión con el hub");
            var bytes = Encoding.UTF8.GetBytes(Json.Escribe(m));
            await _envio.WaitAsync().ConfigureAwait(false);
            try
            {
                await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).ConfigureAwait(false);
            }
            finally
            {
                _envio.Release();
            }
        }

        void AnotaProtocolos(IDictionary<string, object> f)
        {
            if (!f.TryGetValue("protocolos", out var v) || !(v is IDictionary<string, object> m)) return;
            Protocolos = m.Where(kv => kv.Value != null)
                .ToDictionary(kv => kv.Key, kv => Convert.ToString(kv.Value, System.Globalization.CultureInfo.InvariantCulture));
        }

        public List<ImpresoraLocal> Inventario()
        {
            lock (_cerrojoInventario)
            {
                try
                {
                    UltimoInventario = Driver.Inventario();
                }
                catch (Exception e)
                {
                    UltimoError = "No pude leer las impresoras: " + e.Message;
                    Log.Error("driver", UltimoError);
                }
                return UltimoInventario;
            }
        }

        /// <summary>
        /// El motivo de una conexión caída, para el panel y la ventana: quien está
        /// sentado delante necesita saber qué revisar.
        /// </summary>
        public static string MensajeDeConexion(Exception e)
        {
            var web = Busca<WebException>(e);
            var detalle = Interior(e).Message.Trim();
            if (web != null)
            {
                switch (web.Status)
                {
                    case WebExceptionStatus.TrustFailure:
                    case WebExceptionStatus.SecureChannelFailure:
                        return "El certificado del hub no es válido: revisa la fecha y hora de esta computadora.";
                    case WebExceptionStatus.ProtocolError:
                        return $"El hub no aceptó la conexión: ¿se dio de baja este agente o se cambió su credencial? ({detalle})";
                    default:
                        return $"No pude llegar al hub: revisa la conexión a internet de esta computadora. ({detalle})";
                }
            }
            if (Busca<AuthenticationException>(e) != null)
                return "El certificado del hub no es válido: revisa la fecha y hora de esta computadora.";
            if (Busca<System.Net.Sockets.SocketException>(e) != null || Busca<IOException>(e) != null ||
                e is OperationCanceledException)
                return $"No pude llegar al hub: revisa la conexión a internet de esta computadora. ({detalle})";
            if (e is WebSocketException)
                return $"El hub no aceptó la conexión: ¿se dio de baja este agente o se cambió su credencial? ({detalle})";
            return e.Message;
        }

        static T Busca<T>(Exception e) where T : Exception
        {
            for (var x = e; x != null; x = x.InnerException)
                if (x is T t) return t;
            return null;
        }

        static Exception Interior(Exception e)
        {
            while (e.InnerException != null) e = e.InnerException;
            return e;
        }

        static string Detalle(Exception e)
        {
            var partes = new List<string>();
            for (var x = e; x != null; x = x.InnerException) partes.Add(x.GetType().Name + ": " + x.Message);
            return string.Join(" → ", partes);
        }
    }
}
