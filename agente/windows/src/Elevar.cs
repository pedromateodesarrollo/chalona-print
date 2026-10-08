using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace PrintServer
{
    /// <summary>
    /// Pide permiso de administrador para una sola acción: la ventana se vuelve
    /// a lanzar a sí misma con «runas» y espera a que termine.
    ///
    /// Es lo que le faltaba a la 0.2: con doble clic no pedía permiso, la tarea
    /// de arranque no se podía crear y el agente se quedaba en primer plano
    /// —imprimía ese día y desaparecía al reiniciar—.
    ///
    /// La llave no viaja en la línea de órdenes sino en un archivo temporal de
    /// la carpeta del usuario, que el proceso elevado lee y borra al empezar.
    /// </summary>
    static class Elevar
    {
        public sealed class Resultado
        {
            public bool Ok;
            public bool Cancelado;
            public string Mensaje = "";
        }

        const int CanceladoPorElUsuario = 1223; // ERROR_CANCELLED

        public static Resultado Corre(string orden, DatosConexion datos = null)
        {
            var temp = Path.GetTempPath();
            var archivoResultado = Path.Combine(temp, $"print-server-{Guid.NewGuid():N}.txt");
            string archivoDatos = null;
            var args = new List<string> { orden, "--padre", Process.GetCurrentProcess().Id.ToString(), "--resultado", archivoResultado };
            if (datos != null)
            {
                archivoDatos = Path.Combine(temp, $"print-server-{Guid.NewGuid():N}.json");
                File.WriteAllText(archivoDatos, Json.Escribe(new Dictionary<string, object>
                {
                    ["hub"] = datos.Hub,
                    ["llave"] = datos.Llave,
                    ["nombre"] = datos.Nombre,
                }), new UTF8Encoding(false));
                args.Add("--datos");
                args.Add(archivoDatos);
            }

            var r = new Resultado();
            try
            {
                var psi = new ProcessStartInfo(Rutas.EsteEjecutable, Argumentos.Une(args))
                {
                    UseShellExecute = true,
                    Verb = "runas",
                };
                using (var p = Process.Start(psi))
                {
                    p.WaitForExit();
                    r.Ok = p.ExitCode == 0;
                }
                r.Mensaje = File.Exists(archivoResultado) ? File.ReadAllText(archivoResultado, Encoding.UTF8).Trim() : "";
                if (r.Mensaje.Length == 0) r.Mensaje = r.Ok ? "Hecho." : "No se pudo completar, sin más detalle.";
            }
            catch (Win32Exception e) when (e.NativeErrorCode == CanceladoPorElUsuario)
            {
                r.Cancelado = true;
            }
            catch (Exception e)
            {
                r.Mensaje = e.Message;
            }
            finally
            {
                Borra(archivoDatos);
                Borra(archivoResultado);
            }
            return r;
        }

        /// <summary>Lado elevado: lee los datos y borra el archivo en el acto.</summary>
        public static DatosConexion LeeDatos(string ruta)
        {
            try
            {
                var d = Json.LeeObjeto(File.ReadAllText(ruta, Encoding.UTF8));
                return new DatosConexion
                {
                    Hub = Json.Texto(d, "hub"),
                    Llave = Json.Texto(d, "llave"),
                    Nombre = Json.Texto(d, "nombre"),
                };
            }
            finally
            {
                Borra(ruta);
            }
        }

        static void Borra(string ruta)
        {
            try
            {
                if (ruta != null && File.Exists(ruta)) File.Delete(ruta);
            }
            catch (Exception)
            {
            }
        }
    }
}
