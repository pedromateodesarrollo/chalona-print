using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;

namespace PrintServer.Agente
{
    /// <summary>Un alta que el hub rechazó, con su motivo.</summary>
    sealed class AltaRechazada : Exception
    {
        public AltaRechazada(string mensaje) : base(mensaje) { }
    }

    /// <summary>
    /// Da de alta esta computadora en el hub con la llave de API
    /// (<c>POST /v1/agentes/registrar</c>, idempotente por huella).
    ///
    /// A cambio el hub devuelve una credencial propia de esta máquina, que es la
    /// que queda guardada. <b>La llave de API no se guarda.</b>
    /// </summary>
    static class Alta
    {
        public static void Registra(ConfigLocal config, string hub, string llave, string nombre, string ruta = null)
        {
            var url = Normaliza(hub);
            if (url == null)
                throw new ArgumentException("La dirección del hub no es válida (ej: https://print.chalonasoft.com)");
            llave = (llave ?? "").Trim();
            if (!llave.StartsWith("cpk_", StringComparison.Ordinal))
                throw new ArgumentException("La llave de API empieza por «cpk_»; revisa lo que pegaste");
            nombre = (nombre ?? "").Trim();

            var huella = config.Huella.Length == 0 ? ConfigLocal.HuellaDeLaMaquina() : config.Huella;
            var cuerpo = Encoding.UTF8.GetBytes(Json.Escribe(new Dictionary<string, object>
            {
                ["huella"] = huella,
                ["nombre"] = nombre.Length == 0 ? Equipo.Host() : nombre,
                ["plataforma"] = Equipo.Plataforma(),
                ["version"] = VersionAgente.Numero,
            }));

            var pet = (HttpWebRequest)WebRequest.Create(url + "/v1/agentes/registrar");
            pet.Method = "POST";
            pet.ContentType = "application/json";
            pet.Headers["authorization"] = "Bearer " + llave;
            pet.Timeout = 30000;
            pet.ReadWriteTimeout = 30000;
            using (var s = pet.GetRequestStream()) s.Write(cuerpo, 0, cuerpo.Length);

            int estado;
            string texto;
            try
            {
                using (var res = (HttpWebResponse)pet.GetResponse())
                {
                    estado = (int)res.StatusCode;
                    texto = Lee(res);
                }
            }
            catch (WebException e) when (e.Response is HttpWebResponse r)
            {
                using (r)
                {
                    estado = (int)r.StatusCode;
                    texto = Lee(r);
                }
            }

            object d;
            try
            {
                d = Json.Lee(texto);
            }
            catch (FormatException)
            {
                if (estado == 200) throw;
                d = null;
            }
            var m = d as IDictionary<string, object>;
            if (estado != 200 || m == null)
            {
                if (m == null && estado != 200 && !texto.TrimStart().StartsWith("{", StringComparison.Ordinal))
                    throw new FormatException("no es JSON");
                var mensaje = m != null ? Json.Texto(m, "mensaje", Json.Texto(m, "error")) : texto;
                throw new AltaRechazada($"El hub rechazó el alta ({estado}): {mensaje}");
            }

            config.Hub = url;
            config.Huella = huella;
            config.Agente = Json.Numero(m, "agente");
            config.Nombre = Json.Texto(m, "nombre", nombre);
            config.Credencial = Json.Texto(m, "credencial");
            if (config.Agente <= 0 || config.Credencial.Length == 0)
                throw new FormatException("respuesta sin agente ni credencial");
            config.Guarda(ruta);
            Log.Info("registro", $"dado de alta como agente {config.Agente} en {url}");
        }

        /// <summary>
        /// El motivo de un alta fallida, dicho para quien está instalando: la
        /// dirección, la llave o la conexión.
        /// </summary>
        public static string Mensaje(Exception e)
        {
            switch (e)
            {
                case ArgumentException a:
                    return a.Message;
                case AltaRechazada r:
                    return r.Message;
                case WebException w when w.Status == WebExceptionStatus.TrustFailure || w.Status == WebExceptionStatus.SecureChannelFailure:
                    return "El hub contestó, pero su certificado no es válido: revisa la dirección (¿https?) " +
                           "y la fecha y hora de esta computadora.";
                case WebException _:
                case IOException _:
                    return "No pude llegar al hub: revisa la dirección y que esta computadora tenga internet.";
                case FormatException _:
                    return "Lo que contestó esa dirección no es un hub de print-server: revisa la dirección.";
                default:
                    return e.Message;
            }
        }

        /// <summary>
        /// Esquema, host, puerto y —si el hub vive bajo un prefijo— la ruta base
        /// sin barra final. El resto del agente compone <c>$hub/v1/...</c>.
        /// </summary>
        public static string Normaliza(string hub)
        {
            var v = (hub ?? "").Trim();
            if (v.Length == 0) return null;
            if (!v.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                !v.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                v = "https://" + v;
            if (!Uri.TryCreate(v, UriKind.Absolute, out var u) || u.Host.Length == 0) return null;
            var puerto = u.IsDefaultPort ? "" : ":" + u.Port;
            return $"{u.Scheme}://{u.Host}{puerto}{u.AbsolutePath.TrimEnd('/')}";
        }

        static string Lee(HttpWebResponse res)
        {
            using (var r = new StreamReader(res.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }
    }

    static class VersionAgente
    {
        /// <summary>
        /// La versión del agente, que es la del paquete. Se reporta al hub y sale
        /// en el panel; el hub la mira para no mandarle algo que no entienda.
        /// </summary>
        public static string Numero => Rutas.Version;

        /// <summary>Versión del protocolo del WebSocket. Ver docs/protocolo-ws.md.</summary>
        public const int Protocolo = 1;
    }
}
