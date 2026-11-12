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
        /// agente salen juntos (son el mismo .exe).
        /// </summary>
        public static string Version =>
            Versiones.Corta(Assembly.GetExecutingAssembly().GetName().Version.ToString());

        /// <summary>Este mismo .exe, se llame como se llame tras descargarlo.</summary>
        public static string EsteEjecutable => Assembly.GetExecutingAssembly().Location;

        public static string Programa => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "print-server");

        public static string Ventana => Path.Combine(Programa, "print-server.exe");

        /// <summary>
        /// Una copia de este mismo .exe con otro nombre: el servicio lo arranca como
        /// proceso aparte (<c>print-server-agente.exe correr</c>), que se reconoce en
        /// el Administrador de tareas y se puede matar sin tumbar al servicio.
        /// </summary>
        public static string Agente => Path.Combine(Programa, "print-server-agente.exe");

        /// <summary>
        /// La carpeta del agente: <c>ProgramData\print-server</c>, la misma que
        /// usaba el agente de Dart (<c>ConfigAgente.rutaPorDefecto()</c>).
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
