using System;
using System.Collections.Generic;
using System.IO;

namespace PrintServer.Agente
{
    /// <summary>
    /// Log del agente: a la salida estándar y a un anillo en memoria que lee el panel.
    ///
    /// El anillo es lo que ve quien abre la ventana cuando «no imprime»: sin eso
    /// hay que enseñarle a buscar el visor de eventos de Windows, y eso no va a
    /// pasar. La salida la recoge el servicio en <c>ProgramData\print-server\agente.log</c>.
    /// </summary>
    static class Log
    {
        const int Maximo = 200;
        static readonly object Cerrojo = new object();
        static readonly LinkedList<string> UltimasLineas = new LinkedList<string>();

        /// <summary>Adónde va cada línea; la orden de consola la apunta a su salida.</summary>
        public static TextWriter Salida = TextWriter.Null;

        public static void Info(string etiqueta, string mensaje) => Linea("info", etiqueta, mensaje);
        public static void Aviso(string etiqueta, string mensaje) => Linea("aviso", etiqueta, mensaje);
        public static void Error(string etiqueta, string mensaje) => Linea("error", etiqueta, mensaje);

        /// <summary>De la más vieja a la más nueva.</summary>
        public static List<string> Ultimas()
        {
            lock (Cerrojo) return new List<string>(UltimasLineas);
        }

        static void Linea(string nivel, string etiqueta, string mensaje)
        {
            // La misma forma que el agente de Dart (toIso8601String de la hora local).
            var linea = $"{DateTime.Now:yyyy-MM-dd'T'HH:mm:ss.ffffff} {nivel} [{etiqueta}] {mensaje}";
            lock (Cerrojo)
            {
                UltimasLineas.AddLast(linea);
                while (UltimasLineas.Count > Maximo) UltimasLineas.RemoveFirst();
                try
                {
                    Salida.WriteLine(linea);
                }
                catch (Exception)
                {
                    // Sin salida (nadie la lee) el agente sigue imprimiendo.
                }
            }
        }
    }
}
