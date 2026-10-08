using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace PrintServer
{
    /// <summary>
    /// Lo que la ventana necesita saber del archivo de configuración del agente
    /// (<c>agente.json</c>, lo escribe el agente al conectarse).
    ///
    /// La credencial no se guarda aquí: basta con saber si hay una. Esta clase
    /// alimenta una ventana, y lo que no se carga no se puede enseñar por error.
    /// </summary>
    sealed class ConfigAgente
    {
        public string Hub = "";
        public string Nombre = "";
        public long Agente;
        public int PuertoPanel = 7717;
        public bool TieneCredencial;

        /// <summary>
        /// El archivo existe pero esta cuenta no puede leerlo. Pasa a propósito:
        /// lleva la credencial y la instalación lo deja solo para SYSTEM y
        /// administradores. Que exista ya dice que la computadora está conectada.
        /// </summary>
        public bool Protegido;

        public bool Configurado => Protegido || (Hub.Length > 0 && TieneCredencial);

        public static ConfigAgente Desde(string json)
        {
            var d = Json.LeeObjeto(json);
            var puerto = (int)Json.Numero(d, "puerto_panel", 7717);
            return new ConfigAgente
            {
                Hub = Json.Texto(d, "hub"),
                Nombre = Json.Texto(d, "nombre"),
                Agente = Json.Numero(d, "agente"),
                PuertoPanel = puerto > 0 && puerto < 65536 ? puerto : 7717,
                TieneCredencial = Json.Texto(d, "credencial").Length > 0,
            };
        }

        /// <summary>Null si no hay archivo o no se entiende.</summary>
        public static ConfigAgente Lee(string ruta)
        {
            try
            {
                if (!File.Exists(ruta)) return null;
                using (var f = new FileStream(ruta, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(f))
                    return Desde(r.ReadToEnd());
            }
            catch (UnauthorizedAccessException)
            {
                return new ConfigAgente { Protegido = true };
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>Una impresora como la ve el agente.</summary>
    sealed class Impresora
    {
        public string Sistema = "";
        public string Nombre = "";
        public string Estado = "";
        public string Detalle = "";
        public bool Predeterminada;
    }

    /// <summary>
    /// Lo que contesta el panel local del agente en <c>/estado.json</c>. Es la
    /// misma fuente que usaba la página del navegador: la ventana no habla con
    /// el hub, le pregunta al agente.
    /// </summary>
    sealed class EstadoAgente
    {
        public bool Configurado;
        public bool Conectado;
        public string Hub = "";
        public long Agente;
        public string Nombre = "";
        public string Version = "";
        public string Driver = "";

        /// <summary>
        /// <c>servicio</c> si lo arrancó el servicio de Windows. Vacío en los
        /// agentes anteriores a la 0.4, que no lo decían.
        /// </summary>
        public string Modo = "";

        public DateTime? ConectadoDesde;
        public long Impresos;
        public long Fallidos;
        public string UltimoError = "";
        public List<Impresora> Impresoras = new List<Impresora>();

        /// <summary>De la más vieja a la más nueva.</summary>
        public List<string> Registro = new List<string>();

        public bool EsServicio => Modo == "servicio";

        public static EstadoAgente Desde(string json)
        {
            var d = Json.LeeObjeto(json);
            var e = new EstadoAgente
            {
                Configurado = Json.Booleano(d, "configurado"),
                Conectado = Json.Booleano(d, "conectado"),
                Hub = Json.Texto(d, "hub"),
                Agente = Json.Numero(d, "agente"),
                Nombre = Json.Texto(d, "nombre"),
                Version = Json.Texto(d, "version"),
                Driver = Json.Texto(d, "driver"),
                Modo = Json.Texto(d, "modo"),
                ConectadoDesde = Fechas.Lee(Json.Texto(d, "conectado_desde")),
                Impresos = Json.Numero(d, "impresos"),
                Fallidos = Json.Numero(d, "fallidos"),
                UltimoError = Json.Texto(d, "ultimo_error"),
            };
            foreach (var x in Json.Lista(d, "impresoras").OfType<IDictionary<string, object>>())
            {
                e.Impresoras.Add(new Impresora
                {
                    Sistema = Json.Texto(x, "sistema"),
                    Nombre = Json.Texto(x, "nombre"),
                    Estado = Json.Texto(x, "estado"),
                    Detalle = Json.Texto(x, "detalle"),
                    Predeterminada = Json.Booleano(x, "predeterminada"),
                });
            }
            // El panel manda las 50 últimas con la más nueva primero; un registro
            // se lee de arriba abajo.
            e.Registro = Json.Lista(d, "log").OfType<string>().Reverse().ToList();
            return e;
        }
    }

    static class Fechas
    {
        /// <summary>
        /// El agente manda la hora local sin zona (<c>toIso8601String</c> de una
        /// fecha local de Dart); si alguna vez llega en UTC, se pasa a local.
        /// </summary>
        public static DateTime? Lee(string iso)
        {
            if (string.IsNullOrWhiteSpace(iso)) return null;
            if (!DateTime.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var f))
                return null;
            return f.Kind == DateTimeKind.Utc ? f.ToLocalTime() : f;
        }

        public static string Escribe(DateTime f) =>
            f.ToString("dd/MM/yyyy HH:mm:ss", CultureInfo.InvariantCulture);
    }

    static class Textos
    {
        public static string EstadoImpresora(string e)
        {
            switch (e)
            {
                case "lista": return "Lista";
                case "ocupada": return "Ocupada";
                case "pausada": return "En pausa";
                case "sin_papel": return "Sin papel";
                case "error": return "Con error";
                case "desconocida": return "Desconocida";
                default: return string.IsNullOrEmpty(e) ? "—" : e;
            }
        }

        /// <summary>«3 · Duralon-Recepcion (servicio, driver windows+sumatra)».</summary>
        public static string Agente(EstadoAgente e)
        {
            var modo = e.Modo.Length > 0 ? e.Modo : "versión " + e.Version;
            var quien = e.Agente > 0 ? $"{e.Agente} · {e.Nombre}" : e.Nombre;
            return $"{quien} ({modo}, driver {e.Driver})";
        }

        public static string Trabajos(EstadoAgente e) =>
            $"{e.Impresos} impreso{(e.Impresos == 1 ? "" : "s")} · {e.Fallidos} fallido{(e.Fallidos == 1 ? "" : "s")}";
    }

    static class Versiones
    {
        /// <summary>
        /// Compara «0.4.0» con «0.10.1» como números, no como texto. Lo que venga
        /// tras un «-» o un «+» no cuenta. Una versión ilegible vale 0.
        /// </summary>
        public static int Compara(string a, string b)
        {
            var x = Partes(a);
            var y = Partes(b);
            for (var i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                var p = i < x.Length ? x[i] : 0;
                var q = i < y.Length ? y[i] : 0;
                if (p != q) return p.CompareTo(q);
            }
            return 0;
        }

        static int[] Partes(string v)
        {
            v = (v ?? "").Trim();
            var corte = v.IndexOfAny(new[] { '-', '+', ' ' });
            if (corte >= 0) v = v.Substring(0, corte);
            return v.Split('.')
                .Select(s => int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0)
                .ToArray();
        }

        /// <summary>«0.4.0.0» → «0.4.0».</summary>
        public static string Corta(string v)
        {
            var p = Partes(v);
            if (p.Length == 0) return "";
            var n = Math.Max(3, p.Length);
            while (n > 3 && p[n - 1] == 0) n--;
            return string.Join(".", p.Take(n).Concat(Enumerable.Repeat(0, Math.Max(0, n - p.Length))));
        }
    }
}
