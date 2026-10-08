using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;

namespace PrintServer
{
    /// <summary>
    /// El panel local del agente (127.0.0.1). Es la única forma en que la
    /// ventana sabe qué pasa: no habla con el hub ni con el spooler, le
    /// pregunta al agente que ya lo sabe.
    /// </summary>
    static class Panel
    {
        /// <summary>Null si el agente no contesta.</summary>
        public static EstadoAgente Estado(int puerto)
        {
            try
            {
                var pet = Peticion(puerto, "/estado.json", "GET");
                using (var res = (HttpWebResponse)pet.GetResponse())
                    return EstadoAgente.Desde(Lee(res));
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>Manda la página de prueba; el agente la arma en el idioma de esa impresora.</summary>
        public static (bool ok, string mensaje) Prueba(int puerto, string impresora)
        {
            try
            {
                var pet = Peticion(puerto, "/probar", "POST");
                pet.Timeout = 30000;
                pet.ContentType = "application/json";
                var cuerpo = Encoding.UTF8.GetBytes(Json.Escribe(new Dictionary<string, object> { ["impresora"] = impresora }));
                using (var s = pet.GetRequestStream()) s.Write(cuerpo, 0, cuerpo.Length);
                using (var res = (HttpWebResponse)pet.GetResponse())
                {
                    var d = Json.LeeObjeto(Lee(res));
                    var lenguaje = Json.Texto(d, "lenguaje");
                    return (true, lenguaje.Length > 0
                        ? $"Mandada a «{impresora}» (en {lenguaje.ToUpperInvariant()})."
                        : $"Mandada a «{impresora}».");
                }
            }
            catch (WebException e) when (e.Response is HttpWebResponse r)
            {
                // El agente explica el fallo en el cuerpo; sin esto solo se vería «500».
                try
                {
                    using (r) return (false, Json.Texto(Json.LeeObjeto(Lee(r)), "mensaje", e.Message));
                }
                catch (Exception)
                {
                    return (false, e.Message);
                }
            }
            catch (Exception e)
            {
                return (false, "El agente no contesta: " + e.Message);
            }
        }

        static HttpWebRequest Peticion(int puerto, string ruta, string metodo)
        {
            var pet = (HttpWebRequest)WebRequest.Create($"http://127.0.0.1:{puerto}{ruta}");
            pet.Method = metodo;
            pet.Timeout = 2000;
            pet.ReadWriteTimeout = 2000;
            // Sin esto, un proxy del sistema puede meterse incluso con 127.0.0.1
            // y cada consulta tarda segundos.
            pet.Proxy = null;
            return pet;
        }

        static string Lee(HttpWebResponse res)
        {
            using (var r = new StreamReader(res.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }
    }
}
