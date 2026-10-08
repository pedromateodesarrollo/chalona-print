using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace PrintServer
{
    /// <summary>
    /// La línea de órdenes: el primer argumento es la orden (<c>--instalar</c>,
    /// <c>--servicio</c>…) y el resto, opciones <c>--clave valor</c>.
    /// </summary>
    sealed class Argumentos
    {
        public string Orden = "";
        public readonly Dictionary<string, string> Opciones = new Dictionary<string, string>();

        public static Argumentos Lee(string[] args)
        {
            var a = new Argumentos();
            if (args.Length > 0) a.Orden = args[0].Trim().ToLowerInvariant();
            for (var i = 1; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--")) continue;
                var clave = args[i].Substring(2);
                var igual = clave.IndexOf('=');
                if (igual >= 0)
                    a.Opciones[clave.Substring(0, igual)] = clave.Substring(igual + 1);
                else if (i + 1 < args.Length && !args[i + 1].StartsWith("--"))
                    a.Opciones[clave] = args[++i];
                else
                    a.Opciones[clave] = "";
            }
            return a;
        }

        public string Opcion(string clave) => Opciones.TryGetValue(clave, out var v) ? v : "";

        public bool Tiene(string clave) => Opciones.ContainsKey(clave);

        /// <summary>
        /// Une argumentos en una línea de órdenes de Windows, citando como manda
        /// <c>CommandLineToArgvW</c>: comillas alrededor si hay espacios, y las
        /// barras que van antes de una comilla se duplican.
        ///
        /// Importa con una ruta como «C:\Users\Ana María\Temp\» o un nombre de
        /// computadora con espacios: mal citado, el agente recibe otra cosa.
        /// </summary>
        public static string Une(IEnumerable<string> args) => string.Join(" ", args.Select(Cita));

        public static string Cita(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return a;
            var sb = new StringBuilder("\"");
            var barras = 0;
            foreach (var c in a)
            {
                if (c == '\\') { barras++; continue; }
                if (c == '"')
                {
                    sb.Append('\\', barras * 2 + 1).Append('"');
                }
                else
                {
                    sb.Append('\\', barras).Append(c);
                }
                barras = 0;
            }
            // Las barras del final van antes de la comilla de cierre: se duplican.
            sb.Append('\\', barras * 2).Append('"');
            return sb.ToString();
        }
    }
}
