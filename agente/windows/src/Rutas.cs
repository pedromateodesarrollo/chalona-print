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

        /// <summary>
        /// <c>C:\Program Files\print-server</c> con cualquiera de los dos paquetes.
        /// Un proceso de 32 bits en una Windows de 64 ve «Program Files (x86)»
        /// como ProgramFiles: sin esto el x86 y el x64 se instalarían en dos
        /// carpetas y uno no vería al otro al actualizar.
        /// </summary>
        public static string Programa => Path.Combine(ProgramFilesNativo(), "print-server");

        static string ProgramFilesNativo()
        {
            var nativo = Environment.GetEnvironmentVariable("ProgramW6432");
            return string.IsNullOrEmpty(nativo)
                ? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)
                : nativo;
        }

        /// <summary>
        /// HKLM en su vista nativa: un proceso de 32 bits vería la de 32
        /// (WOW6432Node), y el arranque del icono quedaría donde el de 64 no lo
        /// encuentra ni lo quita.
        /// </summary>
        public static Microsoft.Win32.RegistryKey Hklm() => Microsoft.Win32.RegistryKey.OpenBaseKey(
            Microsoft.Win32.RegistryHive.LocalMachine,
            Environment.Is64BitOperatingSystem ? Microsoft.Win32.RegistryView.Registry64 : Microsoft.Win32.RegistryView.Registry32);

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
