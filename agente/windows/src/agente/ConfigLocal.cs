using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace PrintServer.Agente
{
    /// <summary>
    /// Lo que el agente guarda en disco: <c>ProgramData\print-server\agente.json</c>.
    ///
    /// Mismo archivo y mismos campos que el agente de Dart, para que instalar
    /// esta versión encima de aquella conserve la conexión: misma credencial,
    /// mismo número de agente, misma huella.
    ///
    /// Para instalar hacen falta dos datos: la URL del hub y una llave de API. Con
    /// eso el agente se registra solo y consigue su credencial; la llave no se
    /// guarda, porque una llave de organización sentada en cada computadora del
    /// almacén es una llave que se filtra.
    /// </summary>
    sealed class ConfigLocal
    {
        public string Hub = "";
        public string Credencial = "";
        public long Agente;
        public string Nombre = "";
        public string Huella = "";

        /// <summary><c>auto</c>, <c>windows</c> o <c>falso</c>.</summary>
        public string Driver = "auto";

        /// <summary>
        /// Puerto del panel local. Escucha solo en 127.0.0.1: es lo que lee la
        /// ventana de quien está sentado en esa computadora, no un servicio de red.
        /// </summary>
        public int PuertoPanel = 7717;

        public string SalidaFalsa = "";

        /// <summary>
        /// El archivo existe pero esta cuenta no puede leerlo. Distingue «sin
        /// configurar» de «configurado, pero hace falta ser administrador».
        /// </summary>
        public bool Ilegible;

        public bool Configurado => Hub.Length > 0 && Credencial.Length > 0;

        /// <summary>URL del WebSocket a partir de la del hub: http→ws, https→wss, con el prefijo si lo hay.</summary>
        public string UrlWs
        {
            get
            {
                var u = new Uri(Hub);
                var b = new UriBuilder(u) { Scheme = u.Scheme == "https" ? "wss" : "ws", Query = "", Fragment = "" };
                b.Path = u.AbsolutePath.TrimEnd('/') + "/agente/ws";
                if (u.IsDefaultPort) b.Port = -1;
                return b.Uri.ToString();
            }
        }

        // ------------------------------------------------------------------ disco

        /// <summary>
        /// Dónde vive el archivo. <c>PRINT_AGENTE_CONFIG</c> lo cambia (lo usan las
        /// pruebas para imprimir sin tocar la conexión de verdad).
        /// </summary>
        public static string RutaPorDefecto()
        {
            var env = (Environment.GetEnvironmentVariable("PRINT_AGENTE_CONFIG") ?? "").Trim();
            if (env.Length > 0) return env;
            return Rutas.Config;
        }

        /// <summary>
        /// Lee la configuración. Si no se puede —no existe, o no hay permiso—
        /// devuelve una vacía en vez de reventar: listar impresoras no necesita
        /// la credencial.
        /// </summary>
        public static ConfigLocal Carga(string ruta = null)
        {
            ruta = ruta ?? RutaPorDefecto();
            string texto;
            try
            {
                if (!File.Exists(ruta)) return new ConfigLocal();
                using (var f = new FileStream(ruta, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(f, Encoding.UTF8))
                    texto = r.ReadToEnd();
            }
            catch (UnauthorizedAccessException)
            {
                return new ConfigLocal { Ilegible = true };
            }
            catch (IOException)
            {
                return new ConfigLocal { Ilegible = true };
            }

            System.Collections.Generic.IDictionary<string, object> d;
            try
            {
                d = Json.LeeObjeto(texto);
            }
            catch (FormatException)
            {
                return new ConfigLocal();
            }
            var puerto = (int)Json.Numero(d, "puerto_panel", 7717);
            return new ConfigLocal
            {
                Hub = Json.Texto(d, "hub"),
                Credencial = Json.Texto(d, "credencial"),
                Agente = Json.Numero(d, "agente"),
                Nombre = Json.Texto(d, "nombre"),
                Huella = Json.Texto(d, "huella"),
                Driver = Json.Texto(d, "driver", "auto"),
                PuertoPanel = puerto > 0 && puerto < 65536 ? puerto : 7717,
                SalidaFalsa = Json.Texto(d, "salida_falsa"),
            };
        }

        /// <summary>
        /// Escribe el archivo. Si ya existía se sobrescribe en el sitio: conserva
        /// los permisos que le dejó la instalación (solo SYSTEM y administradores).
        /// </summary>
        public void Guarda(string ruta = null)
        {
            ruta = ruta ?? RutaPorDefecto();
            Directory.CreateDirectory(Path.GetDirectoryName(ruta));
            var sb = new StringBuilder("{\n");
            void Campo(string clave, object valor, bool ultimo = false) =>
                sb.Append("  ").Append(Json.Escribe(clave)).Append(": ").Append(Json.Escribe(valor)).Append(ultimo ? "\n" : ",\n");
            Campo("hub", Hub);
            Campo("credencial", Credencial);
            Campo("agente", Agente);
            Campo("nombre", Nombre);
            Campo("huella", Huella);
            Campo("driver", Driver);
            Campo("puerto_panel", PuertoPanel);
            Campo("salida_falsa", SalidaFalsa, true);
            sb.Append("}");
            File.WriteAllText(ruta, sb.ToString(), new UTF8Encoding(false));
        }

        // -------------------------------------------------------------- identidad

        /// <summary>
        /// Identidad estable de la máquina: <c>host:MachineGuid</c>, como la del
        /// agente de Dart. Reinstalar no crea un duplicado en el hub.
        /// </summary>
        public static string HuellaDeLaMaquina()
        {
            var host = Equipo.Host();
            var id = Equipo.MachineGuid();
            if (!string.IsNullOrEmpty(id)) return host + ":" + id;
            var azar = new byte[8];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(azar);
            var sb = new StringBuilder(host).Append(':');
            foreach (var b in azar) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            return sb.ToString();
        }
    }

    /// <summary>Lo que se reporta de esta computadora.</summary>
    static class Equipo
    {
        /// <summary>El nombre de red (lo mismo que <c>Platform.localHostname</c> de Dart).</summary>
        public static string Host()
        {
            try
            {
                return Dns.GetHostName();
            }
            catch (Exception)
            {
                return Environment.MachineName;
            }
        }

        /// <summary>
        /// Se lee de la vista de 64 bits del registro: en un proceso de 32 bits
        /// sobre Windows de 64, la vista por defecto no tiene MachineGuid, y la
        /// huella cambiaría según qué paquete se instaló.
        /// </summary>
        public static string MachineGuid()
        {
            try
            {
                var vista = Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Registry32;
                using (var b = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, vista))
                using (var k = b.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
                    return (k?.GetValue("MachineGuid") as string ?? "").Trim();
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>
        /// «windows "Windows 10 Pro" 10.0 (Build 19045) x86»: lo que decía el agente
        /// de Dart, y la arquitectura del proceso al final.
        /// </summary>
        public static string Plataforma()
        {
            var producto = "Windows";
            var version = Environment.OSVersion.Version;
            var build = version.Build.ToString(CultureInfo.InvariantCulture);
            try
            {
                var vista = Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Registry32;
                using (var b = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, vista))
                using (var k = b.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    producto = k?.GetValue("ProductName") as string ?? producto;
                    build = k?.GetValue("CurrentBuildNumber") as string ?? build;
                }
            }
            catch (Exception)
            {
            }
            // Windows 11 sigue diciendo «Windows 10» en el registro.
            if (int.TryParse(build, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) && n >= 22000)
                producto = producto.Replace("Windows 10", "Windows 11");
            return $"windows \"{producto}\" 10.0 (Build {build}) {Arquitectura()}";
        }

        public static string Arquitectura()
        {
            switch (System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture)
            {
                case System.Runtime.InteropServices.Architecture.X86: return "x86";
                case System.Runtime.InteropServices.Architecture.Arm64: return "arm64";
                case System.Runtime.InteropServices.Architecture.Arm: return "arm";
                default: return "x64";
            }
        }
    }
}
