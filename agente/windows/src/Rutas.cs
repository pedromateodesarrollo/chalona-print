using System;
using System.IO;
using System.Reflection;

namespace PrintServer
{
    /// <summary>Dónde vive cada cosa una vez instalado.</summary>
    static class Rutas
    {
        /// <summary>Nombre del servicio de Windows.</summary>
        public const string Servicio = "print-server";

        /// <summary>
        /// La versión de este programa, que es la del paquete: la ventana y el
        /// agente que lleva dentro salen juntos.
        /// </summary>
        public static string Version =>
            Versiones.Corta(Assembly.GetExecutingAssembly().GetName().Version.ToString());

        /// <summary>Este mismo .exe, se llame como se llame tras descargarlo.</summary>
        public static string EsteEjecutable => Assembly.GetExecutingAssembly().Location;

        public static string Programa => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "print-server");

        public static string Ventana => Path.Combine(Programa, "print-server.exe");

        public static string Agente => Path.Combine(Programa, "print-server-agente.exe");

        /// <summary>
        /// La carpeta del agente: <c>ProgramData\print-server</c>, la misma que
        /// usa <c>ConfigAgente.rutaPorDefecto()</c> en Dart.
        /// </summary>
        public static string Datos => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "print-server");

        public static string Config => Path.Combine(Datos, "agente.json");

        /// <summary>Lo que dice el agente mientras corre como servicio.</summary>
        public static string Registro => Path.Combine(Datos, "agente.log");

        /// <summary>
        /// Las instalaciones de antes del cambio de nombre (septiembre de 2026)
        /// guardaban la configuración aquí. Se trae al instalar para que esas
        /// computadoras no necesiten una llave nueva.
        /// </summary>
        public static string DatosViejos => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "chalona-print");

        public static string ConfigVieja => Path.Combine(DatosViejos, "agente.json");

        public static string Acceso => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "print-server.lnk");

        public static bool EsLaMisma(string a, string b) =>
            string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'),
                StringComparison.OrdinalIgnoreCase);
    }
}
