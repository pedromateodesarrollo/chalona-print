using System;
using System.Collections.Generic;
using System.IO;

namespace PrintServer.Agente
{
    /// <summary>Una impresora tal como la ve el sistema operativo de esta computadora.</summary>
    sealed class ImpresoraLocal
    {
        /// <summary>El nombre con el que la conoce el spooler. Es la llave real.</summary>
        public string Sistema = "";
        public string Nombre = "";
        public string Estado = "";
        public string Detalle = "";
        public long Cola;
        public bool Predeterminada;

        /// <summary>
        /// Qué sabe mandarle este driver. Se reporta al hub para que rechace un PDF
        /// antes de encolarlo, y no después de que nadie imprima.
        /// </summary>
        public List<string> Formatos = new List<string> { "raw" };

        /// <summary>
        /// Para RECONOCERLA, no para imprimir: «Honeywell · USB · serie …» es la
        /// impresora que alguien acaba de conectar y está mirando.
        /// </summary>
        public string Fabricante = "";
        public string Modelo = "";

        /// <summary><c>usb</c>, <c>red</c>, <c>puerto</c>, <c>archivo</c> u <c>otro</c>.</summary>
        public string Conexion = "";
        public string Serie = "";

        public Dictionary<string, object> AJson() => new Dictionary<string, object>
        {
            ["sistema"] = Sistema,
            ["nombre"] = Nombre,
            ["estado"] = Estado,
            ["detalle"] = Detalle,
            ["cola"] = Cola,
            ["predeterminada"] = Predeterminada,
            ["formatos"] = Formatos,
            ["fabricante"] = Fabricante,
            ["modelo"] = Modelo,
            ["conexion"] = Conexion,
            ["serie"] = Serie,
            // El protocolo que el agente deduce solo. El hub lo enseña como
            // «automático» hasta que alguien fije el del modelo o el de la cola.
            ["protocolo"] = Prueba.Protocolo(this, Sistema),
        };
    }

    /// <summary>Estados que reporta el agente. Mismos nombres que usa el hub.</summary>
    static class EstadoImpresora
    {
        public const string Lista = "lista";
        public const string Ocupada = "ocupada";
        public const string Pausada = "pausada";
        public const string SinPapel = "sin_papel";
        public const string Error = "error";
        public const string Desconocida = "desconocida";
    }

    /// <summary>Lo que hay que imprimir.</summary>
    sealed class TrabajoLocal
    {
        public long Id = -1;
        public string Impresora = "";
        public string Formato = "raw";
        public byte[] Contenido = new byte[0];
        public string Nombre = "";
        public int Copias = 1;
        public IDictionary<string, object> Opciones = new Dictionary<string, object>();
    }

    /// <summary>
    /// Fallo de impresión con un mensaje que sirva para arreglarlo. El texto llega
    /// al panel del hub y de ahí a quien está esperando la etiqueta.
    /// </summary>
    sealed class ErrorImpresion : Exception
    {
        public ErrorImpresion(string mensaje) : base(mensaje) { }
    }

    /// <summary>La forma de hablar con el spooler. El resto del agente no sabe cuál usa.</summary>
    interface IDriver
    {
        string Nombre { get; }

        /// <summary>Qué impresoras hay y cómo están, ahora mismo.</summary>
        List<ImpresoraLocal> Inventario();

        /// <summary>
        /// Manda el trabajo al spooler. Vuelve cuando el spooler lo aceptó, que no
        /// es lo mismo que cuando el papel salió: nadie puede prometer eso.
        /// </summary>
        void Imprime(TrabajoLocal t);

        /// <summary>El papel que tiene puesto la cola, en puntos (1/72"), o null.</summary>
        (double ancho, double alto)? Papel(string impresora);
    }

    static class Drivers
    {
        /// <summary>
        /// <c>auto</c> y <c>windows</c> son el spooler; <c>falso</c> escribe los
        /// trabajos en una carpeta, para probar sin gastar papel.
        /// </summary>
        public static IDriver Elige(ConfigLocal config)
        {
            var pedido = (config.Driver ?? "").Trim().ToLowerInvariant();
            if (pedido == "falso")
            {
                var salida = config.SalidaFalsa.Length == 0
                    ? Path.Combine(Path.GetTempPath(), "print-server")
                    : config.SalidaFalsa;
                return new DriverFalso(salida);
            }
            return new DriverWindows();
        }
    }

    /// <summary>
    /// Driver de mentira: escribe los trabajos en una carpeta en vez de imprimir.
    /// Está en el producto a propósito: prueba una integración entera —hub, cola,
    /// agente, reintentos— sin gastar una etiqueta.
    /// </summary>
    sealed class DriverFalso : IDriver
    {
        readonly string _carpeta;
        static readonly List<string> Todos = new List<string> { "raw", "pdf", "imagen", "texto" };

        public DriverFalso(string carpeta) { _carpeta = carpeta; }

        public string Nombre => "falso";

        public List<ImpresoraLocal> Inventario() => new List<ImpresoraLocal>
        {
            new ImpresoraLocal
            {
                Sistema = "falsa-etiquetas", Nombre = "Falsa (etiquetas)", Estado = EstadoImpresora.Lista,
                Detalle = "Escribe en " + _carpeta, Predeterminada = true, Formatos = Todos,
            },
            new ImpresoraLocal
            {
                Sistema = "falsa-rota", Nombre = "Falsa (siempre falla)", Estado = EstadoImpresora.Error,
                Detalle = "Existe para probar el camino del fallo", Formatos = Todos,
            },
        };

        public void Imprime(TrabajoLocal t)
        {
            if (t.Impresora == "falsa-rota") throw new ErrorImpresion("Impresora de prueba: falla siempre, a propósito");
            Directory.CreateDirectory(_carpeta);
            string ext;
            switch (t.Formato)
            {
                case "pdf": ext = "pdf"; break;
                case "imagen": ext = "img"; break;
                case "texto": ext = "txt"; break;
                default: ext = "bin"; break;
            }
            File.WriteAllBytes(Path.Combine(_carpeta, $"trabajo-{t.Id}.{ext}"), t.Contenido);
        }

        public (double ancho, double alto)? Papel(string impresora) => null;
    }

    /// <summary>
    /// Los trabajos que esta computadora ya imprimió (<c>hechos.txt</c> junto a la
    /// configuración, el mismo archivo del agente de Dart).
    ///
    /// Es la pieza que hace segura la reentrega: el hub reenvía lo que no le
    /// confirmaron, y aquí se responde «ese ya salió» sin gastar papel.
    /// </summary>
    sealed class Hechos
    {
        readonly string _archivo;
        readonly int _maximo;
        readonly HashSet<long> _ids = new HashSet<long>();
        readonly List<long> _orden = new List<long>();
        readonly object _cerrojo = new object();

        Hechos(string archivo, int maximo)
        {
            _archivo = archivo;
            _maximo = maximo;
        }

        public static Hechos Abre(string rutaConfig, int maximo = 5000)
        {
            var h = new Hechos(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(rutaConfig)), "hechos.txt"), maximo);
            try
            {
                if (File.Exists(h._archivo))
                {
                    foreach (var linea in File.ReadAllLines(h._archivo))
                    {
                        if (long.TryParse(linea.Trim(), out var id) && h._ids.Add(id)) h._orden.Add(id);
                    }
                }
            }
            catch (Exception)
            {
                // Sin poder leerlo se imprime igual; se pierde la protección tras un reinicio.
            }
            return h;
        }

        public bool Contiene(long id)
        {
            lock (_cerrojo) return _ids.Contains(id);
        }

        public void Anota(long id)
        {
            lock (_cerrojo)
            {
                if (!_ids.Add(id)) return;
                _orden.Add(id);
                try
                {
                    if (_orden.Count > _maximo)
                    {
                        _ids.Remove(_orden[0]);
                        _orden.RemoveAt(0);
                        Directory.CreateDirectory(Path.GetDirectoryName(_archivo));
                        File.WriteAllText(_archivo, string.Join("\n", _orden) + "\n");
                    }
                    else
                    {
                        using (var f = new FileStream(_archivo, FileMode.Append, FileAccess.Write, FileShare.Read))
                        using (var w = new StreamWriter(f))
                        {
                            w.Write(id + "\n");
                            w.Flush();
                            f.Flush(true);
                        }
                    }
                }
                catch (Exception)
                {
                    // El agente sigue imprimiendo; lo que se pierde es la protección
                    // contra el duplicado tras un reinicio.
                }
            }
        }
    }
}
