using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace PrintServer
{
    /// <summary>Lo que se teclea para conectar: dirección del hub, llave y nombre.</summary>
    sealed class DatosConexion
    {
        public string Hub = "";
        public string Llave = "";
        public string Nombre = "";
    }

    /// <summary>
    /// Instalar, conectar, desconectar y desinstalar. Todo esto corre con
    /// permiso de administrador: la ventana se relanza elevada para cada cosa
    /// (ver <see cref="Elevar"/>), así que ella misma nunca lo necesita.
    ///
    /// Lo que queda instalado:
    /// <list type="bullet">
    /// <item><c>Archivos de programa\print-server\</c>: esta ventana y el agente.</item>
    /// <item>El servicio <c>print-server</c>, automático, con la cuenta SYSTEM.</item>
    /// <item>El icono junto al reloj al iniciar sesión y el acceso en el menú Inicio.</item>
    /// </list>
    /// </summary>
    static class Instalacion
    {
        /// <summary>
        /// Lo que dejaron versiones anteriores. Las 0.2 se instalaban como tareas
        /// programadas; la 0.3.0 —la primera con ventana, que no llegó al
        /// repositorio— como servicio con el nombre de antes del cambio de nombre.
        /// No se sabe con certeza cómo lo llamó, así que se buscan los probables.
        /// </summary>
        static readonly string[] ServiciosViejos = { "chalona-print-agente", "chalona-print", "print-server-agente" };
        static readonly string[] TareasViejas =
        {
            "print-server-agente", "print-server-agente-bandeja",
            "chalona-print-agente", "chalona-print-agente-bandeja",
        };

        const string ClaveArranque = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";

        // ------------------------------------------------------------ consultas

        /// <summary>Sin permisos especiales: la ventana lo pregunta cada pocos segundos.</summary>
        public static EstadoServicio Servicio()
        {
            try
            {
                using (var s = new ServiceController(Rutas.Servicio))
                {
                    switch (s.Status)
                    {
                        case ServiceControllerStatus.Running: return EstadoServicio.EnMarcha;
                        case ServiceControllerStatus.StartPending:
                        case ServiceControllerStatus.ContinuePending: return EstadoServicio.Arrancando;
                        case ServiceControllerStatus.StopPending:
                        case ServiceControllerStatus.PausePending: return EstadoServicio.Deteniendo;
                        default: return EstadoServicio.Detenido;
                    }
                }
            }
            catch (InvalidOperationException)
            {
                return EstadoServicio.NoInstalado;
            }
        }

        /// <summary>«0.4.0», o null si no hay nada en Archivos de programa.</summary>
        public static string VersionInstalada()
        {
            try
            {
                if (!File.Exists(Rutas.Ventana)) return null;
                return Versiones.Corta(FileVersionInfo.GetVersionInfo(Rutas.Ventana).FileVersion);
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>
        /// Los servicios de versiones viejas que siguen puestos: los de nombre
        /// conocido y cualquiera cuyo programa viva en una carpeta «chalona-print»
        /// o «print-server» y no sea el nuestro. Por la ruta se encuentra la
        /// 0.3.0 aunque su servicio se llame distinto de lo que suponemos.
        /// </summary>
        public static List<string> ServiciosViejosPresentes()
        {
            var viejos = new List<string>();
            try
            {
                var nombres = new HashSet<string>(ServiciosViejos, StringComparer.OrdinalIgnoreCase);
                using (var raiz = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services"))
                {
                    if (raiz == null) return viejos;
                    foreach (var nombre in raiz.GetSubKeyNames())
                    {
                        if (string.Equals(nombre, Rutas.Servicio, StringComparison.OrdinalIgnoreCase)) continue;
                        string ruta;
                        using (var k = raiz.OpenSubKey(nombre))
                            ruta = (k?.GetValue("ImagePath") as string ?? "").ToLowerInvariant();
                        if (ruta.Length == 0 || ruta.Contains("-hub")) continue;
                        if (nombres.Contains(nombre) || ruta.Contains("chalona-print") || ruta.Contains(@"\print-server\"))
                            viejos.Add(nombre);
                    }
                }
            }
            catch (Exception)
            {
                // Sin poder leer el registro, mejor no inventar nada.
            }
            return viejos;
        }

        public static bool EsAdministrador()
        {
            using (var id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }

        // ------------------------------------------------------------- acciones

        /// <summary>
        /// Instala o actualiza, y conecta si vienen datos. Se puede repetir: lo que
        /// ya esté en su sitio se queda.
        /// </summary>
        /// <param name="padre">La ventana que lo pidió: no se cierra.</param>
        public static string Instala(DatosConexion datos, int padre, RegistroArchivo registro)
        {
            registro.Escribe("instalar", $"instalando la {Rutas.Version}" + (datos != null ? $" y conectando a {datos.Hub}" : ""));
            if (datos != null) Valida(datos);

            Directory.CreateDirectory(Rutas.Programa);
            Directory.CreateDirectory(Rutas.Datos);

            // El agente sale primero a una carpeta temporal y, si hay datos, se
            // conecta desde ahí. Así una llave mala no toca nada: el servicio que
            // ya estuviera imprimiendo sigue imprimiendo.
            var agenteNuevo = Path.Combine(Path.GetTempPath(), $"print-server-agente-{Guid.NewGuid():N}.exe");
            string conectado = null;
            try
            {
                ExtraeAgente(agenteNuevo);
                if (datos != null) conectado = Conecta(agenteNuevo, datos, registro);

                // Ahora sí: se para todo lo que pueda tener los archivos abiertos o
                // estar conectado al hub con la misma credencial.
                DetieneServicio(Rutas.Servicio);
                RetiraLoViejo(registro);
                CierraProcesos(padre);

                var yo = Rutas.EsteEjecutable;
                if (!Rutas.EsLaMisma(yo, Rutas.Ventana)) CopiaConReintentos(yo, Rutas.Ventana);
                CopiaConReintentos(agenteNuevo, Rutas.Agente);
                // PDFium va junto al agente: Windows busca la DLL primero en la
                // carpeta del .exe, y ahí la busca el agente. Con ella imprime
                // PDF por el driver de cualquier impresora.
                ExtraeJunto("pdfium.dll", registro);
                ExtraeJunto("pdfium-licencias.txt", registro);
            }
            finally
            {
                try { File.Delete(agenteNuevo); } catch (Exception) { }
            }
            TraeConfigVieja(registro);
            ProtegeConfig();

            RegistraServicio();
            PonArranque();
            PonAcceso();
            ArrancaServicio(Rutas.Servicio);

            registro.Escribe("instalar", "listo");
            var config = ConfigAgente.Lee(Rutas.Config);
            if (conectado != null) return conectado + "\n\nQuedó instalado como servicio de Windows: sigue imprimiendo después de reiniciar la computadora, aunque nadie inicie sesión.";
            if (config == null || !config.Configurado)
                return "Instalado como servicio, pero sin conectar: no imprime hasta que pongas la dirección y la llave y pulses «Conectar».";
            return "Instalado como servicio y en marcha: sigue imprimiendo después de reiniciar la computadora, aunque nadie inicie sesión.";
        }

        /// <summary>
        /// Borra la credencial: el agente deja de imprimir hasta que se vuelva a
        /// conectar. El servicio se queda puesto, esperando.
        /// </summary>
        public static string Desconecta(RegistroArchivo registro)
        {
            registro.Escribe("instalar", "desconectando");
            DetieneServicio(Rutas.Servicio);
            BorraSiExiste(Rutas.Config);
            BorraSiExiste(Rutas.ConfigVieja);
            if (Servicio() != EstadoServicio.NoInstalado) ArrancaServicio(Rutas.Servicio);
            return "Desconectada. Esta computadora ya no recibe trabajos del hub hasta que se vuelva a conectar con una llave.";
        }

        public static string Inicia()
        {
            ArrancaServicio(Rutas.Servicio);
            return "El servicio está en marcha.";
        }

        /// <summary>Quita todo: servicio, programa, icono, acceso y credencial.</summary>
        public static string Desinstala(int padre, RegistroArchivo registro)
        {
            registro.Escribe("instalar", "desinstalando");
            DetieneServicio(Rutas.Servicio);
            BorraServicio(Rutas.Servicio);
            RetiraLoViejo(registro);
            CierraProcesos(padre);
            QuitaArranque();
            BorraSiExiste(Rutas.Acceso);

            try
            {
                if (Directory.Exists(Rutas.Datos)) Directory.Delete(Rutas.Datos, true);
            }
            catch (Exception)
            {
                // Lo que no se pudo borrar ya no lleva credencial: agente.json se
                // borra aparte, abajo.
                BorraSiExiste(Rutas.Config);
            }

            // Si esta ventana corre desde Archivos de programa, su propio .exe no
            // se puede borrar mientras esté abierto: se deja a un cmd que espera
            // unos segundos a que se cierre.
            var pendiente = false;
            if (Directory.Exists(Rutas.Programa))
            {
                foreach (var f in Directory.GetFiles(Rutas.Programa))
                {
                    try { File.Delete(f); } catch (Exception) { pendiente = true; }
                }
                if (!pendiente)
                {
                    try { Directory.Delete(Rutas.Programa, true); } catch (Exception) { pendiente = true; }
                }
            }
            if (pendiente)
            {
                // Lo intenta cada par de segundos durante algo más de un minuto: la
                // ventana se cierra cuando quien desinstaló acepta el mensaje.
                var dir = Rutas.Programa;
                Process.Start(new ProcessStartInfo("cmd.exe",
                    $"/c for /l %i in (1,1,40) do @(ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{dir}\" 2>nul & if not exist \"{dir}\" exit)")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden,
                });
            }
            return "Desinstalado. Esta computadora ya no imprime lo que mande el hub.";
        }

        // ------------------------------------------------------------- piezas

        static void Valida(DatosConexion d)
        {
            if (d.Hub.Trim().Length == 0) throw new InvalidOperationException("Falta la dirección del hub.");
            if (!d.Llave.Trim().StartsWith("cpk_"))
                throw new InvalidOperationException("La llave de API empieza por «cpk_»: revisa lo que pegaste.");
        }

        /// <summary>El alta la hace el agente, que es quien sabe hablar con el hub.</summary>
        static string Conecta(string agente, DatosConexion d, RegistroArchivo registro)
        {
            var args = new List<string> { "configurar", "--hub", d.Hub.Trim(), "--llave", d.Llave.Trim() };
            if (d.Nombre.Trim().Length > 0) args.AddRange(new[] { "--nombre", d.Nombre.Trim() });
            var psi = new ProcessStartInfo(agente, Argumentos.Une(args))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Path.GetDirectoryName(agente),
            };
            psi.EnvironmentVariables["PRINT_AGENTE_UTF8"] = "1";
            using (var p = Process.Start(psi))
            {
                var salida = p.StandardOutput.ReadToEndAsync();
                var error = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(60000))
                {
                    try { p.Kill(); } catch (Exception) { }
                    throw new InvalidOperationException("El hub no contestó en un minuto: revisa la dirección y la conexión.");
                }
                var texto = (error.Result.Trim().Length > 0 ? error.Result : salida.Result).Trim();
                if (p.ExitCode != 0)
                {
                    registro.Escribe("instalar", "no se pudo conectar: " + texto);
                    throw new InvalidOperationException("No se pudo conectar: " + texto);
                }
            }
            var c = ConfigAgente.Lee(Rutas.Config);
            registro.Escribe("instalar", $"conectada como agente {c?.Agente} en {c?.Hub}");
            return c != null && c.Agente > 0
                ? $"Conectada al hub como agente {c.Agente} · {c.Nombre}."
                : "Conectada al hub.";
        }

        /// <summary>
        /// La configuración lleva la credencial del agente. Heredando los permisos
        /// de ProgramData la podría leer cualquier usuario de la computadora; se
        /// deja solo para SYSTEM —que es quien corre el agente— y administradores.
        /// </summary>
        static void ProtegeConfig()
        {
            if (!File.Exists(Rutas.Config)) return;
            var reglas = new FileSecurity();
            reglas.SetAccessRuleProtection(true, false);
            foreach (var quien in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            {
                reglas.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(quien, null), FileSystemRights.FullControl, AccessControlType.Allow));
            }
            File.SetAccessControl(Rutas.Config, reglas);
        }

        /// <summary>
        /// Las computadoras instaladas antes del cambio de nombre tienen su
        /// conexión en <c>ProgramData\chalona-print</c>. Se trae tal cual —misma
        /// credencial, mismo número de agente— y se borra la vieja.
        /// </summary>
        static void TraeConfigVieja(RegistroArchivo registro)
        {
            if (!Directory.Exists(Rutas.DatosViejos)) return;
            foreach (var f in Directory.GetFiles(Rutas.DatosViejos))
            {
                var destino = Path.Combine(Rutas.Datos, Path.GetFileName(f));
                if (!File.Exists(destino)) File.Copy(f, destino);
            }
            registro.Escribe("instalar", $"traída la configuración de {Rutas.DatosViejos}");
            try { Directory.Delete(Rutas.DatosViejos, true); } catch (Exception) { BorraSiExiste(Rutas.ConfigVieja); }
        }

        static void RetiraLoViejo(RegistroArchivo registro)
        {
            foreach (var s in ServiciosViejosPresentes())
            {
                registro.Escribe("instalar", $"quitando el servicio viejo «{s}»");
                DetieneServicio(s);
                BorraServicio(s);
            }
            foreach (var t in TareasViejas)
            {
                // Lo normal es que no existan: se intenta y ya.
                Corre("schtasks.exe", "/end", "/tn", t);
                if (Corre("schtasks.exe", "/delete", "/tn", t, "/f").codigo == 0)
                    registro.Escribe("instalar", $"quitada la tarea vieja «{t}»");
            }
            using (var clave = Registry.LocalMachine.OpenSubKey(ClaveArranque, true))
            {
                if (clave == null) return;
                foreach (var v in clave.GetValueNames().Where(n => n.StartsWith("chalona-print", StringComparison.OrdinalIgnoreCase)))
                    clave.DeleteValue(v, false);
            }
        }

        /// <summary>
        /// Cierra lo que quede de print-server o chalona-print corriendo: iconos
        /// de la bandeja, agentes en primer plano de una instalación que no llegó
        /// a quedar como servicio, ventanas viejas. Salvo este proceso y la
        /// ventana que lo pidió.
        /// </summary>
        static void CierraProcesos(int padre)
        {
            var yo = Process.GetCurrentProcess().Id;
            foreach (var p in Process.GetProcesses())
            {
                try
                {
                    if (p.Id == yo || p.Id == padre) continue;
                    var n = p.ProcessName;
                    if (!n.StartsWith("print-server", StringComparison.OrdinalIgnoreCase)
                        && !n.StartsWith("chalona-print", StringComparison.OrdinalIgnoreCase)) continue;
                    // Un hub levantado en esta misma máquina no es cosa del agente.
                    if (n.IndexOf("-hub", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    p.Kill();
                    p.WaitForExit(5000);
                }
                catch (Exception)
                {
                    // Ya terminó, o es de otra sesión sin permiso: no impide instalar.
                }
                finally
                {
                    p.Dispose();
                }
            }
        }

        /// <summary>
        /// Saca un recurso del paquete a Archivos de programa, junto al agente.
        /// Un paquete compilado sin él (los de antes de la 0.5.0) sigue
        /// instalando: el agente solo no ofrece PDF.
        /// </summary>
        static void ExtraeJunto(string nombre, RegistroArchivo registro)
        {
            var temporal = Path.Combine(Path.GetTempPath(), $"print-server-{Guid.NewGuid():N}-{nombre}");
            try
            {
                using (var r = Assembly.GetExecutingAssembly().GetManifestResourceStream(nombre))
                {
                    if (r == null)
                    {
                        registro.Escribe("instalar", $"este paquete no trae {nombre}");
                        return;
                    }
                    using (var f = File.Create(temporal)) r.CopyTo(f);
                }
                CopiaConReintentos(temporal, Path.Combine(Rutas.Programa, nombre));
            }
            finally
            {
                try { File.Delete(temporal); } catch (Exception) { }
            }
        }

        static void ExtraeAgente(string destino)
        {
            using (var r = Assembly.GetExecutingAssembly().GetManifestResourceStream("print-server-agente.exe"))
            {
                if (r == null)
                    throw new InvalidOperationException(
                        "Este programa se compiló sin el agente dentro y no puede instalarse. " +
                        "Descarga el de Windows desde el hub.");
                using (var f = File.Create(destino)) r.CopyTo(f);
            }
        }

        static void CopiaConReintentos(string origen, string destino)
        {
            for (var i = 0; ; i++)
            {
                try
                {
                    File.Copy(origen, destino, true);
                    return;
                }
                catch (IOException) when (i < 20)
                {
                    // Un proceso recién cerrado tarda un momento en soltar el archivo.
                    Thread.Sleep(500);
                }
            }
        }

        static void RegistraServicio()
        {
            var binPath = $"\"{Rutas.Ventana}\" --servicio";
            var existe = Servicio() != EstadoServicio.NoInstalado;
            var r = existe
                ? Corre("sc.exe", "config", Rutas.Servicio, "binPath=", binPath, "start=", "auto", "DisplayName=", "print-server")
                : Corre("sc.exe", "create", Rutas.Servicio, "binPath=", binPath, "start=", "auto", "DisplayName=", "print-server");
            if (r.codigo != 0) throw new InvalidOperationException("No se pudo registrar el servicio: " + r.salida);
            Corre("sc.exe", "description", Rutas.Servicio,
                "Agente de print-server: recoge del hub los trabajos de impresión y los manda a las impresoras de esta computadora.");
            // Si el servicio mismo se cae, Windows lo vuelve a levantar.
            Corre("sc.exe", "failure", Rutas.Servicio, "reset=", "86400", "actions=", "restart/5000/restart/10000/restart/60000");
        }

        static void BorraServicio(string nombre)
        {
            Corre("sc.exe", "delete", nombre);
        }

        static void DetieneServicio(string nombre)
        {
            try
            {
                using (var s = new ServiceController(nombre))
                {
                    if (s.Status == ServiceControllerStatus.Stopped) return;
                    if (s.Status != ServiceControllerStatus.StopPending) s.Stop();
                    s.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                }
            }
            catch (InvalidOperationException)
            {
                // No existe.
            }
            catch (System.ServiceProcess.TimeoutException)
            {
                throw new InvalidOperationException($"El servicio «{nombre}» no se detuvo en 30 segundos.");
            }
        }

        static void ArrancaServicio(string nombre)
        {
            using (var s = new ServiceController(nombre))
            {
                if (s.Status == ServiceControllerStatus.Running) return;
                if (s.Status != ServiceControllerStatus.StartPending) s.Start();
                try
                {
                    s.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                }
                catch (System.ServiceProcess.TimeoutException)
                {
                    throw new InvalidOperationException("El servicio no arrancó en 30 segundos. Mira el registro en la ventana.");
                }
            }
        }

        /// <summary>El icono de la bandeja, para todo el que inicie sesión.</summary>
        static void PonArranque()
        {
            using (var clave = Registry.LocalMachine.CreateSubKey(ClaveArranque))
                clave.SetValue("print-server", $"\"{Rutas.Ventana}\" --bandeja");
        }

        static void QuitaArranque()
        {
            using (var clave = Registry.LocalMachine.OpenSubKey(ClaveArranque, true))
                clave?.DeleteValue("print-server", false);
        }

        /// <summary>Acceso en el menú Inicio. Si falla no pasa nada: es comodidad.</summary>
        static void PonAcceso()
        {
            try
            {
                var tipo = Type.GetTypeFromProgID("WScript.Shell");
                var shell = Activator.CreateInstance(tipo);
                var acceso = tipo.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { Rutas.Acceso });
                var t = acceso.GetType();
                t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, acceso, new object[] { Rutas.Ventana });
                t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, acceso, new object[] { Rutas.Programa });
                t.InvokeMember("Description", BindingFlags.SetProperty, null, acceso, new object[] { "Agente de impresión" });
                t.InvokeMember("Save", BindingFlags.InvokeMethod, null, acceso, null);
            }
            catch (Exception)
            {
            }
        }

        static void BorraSiExiste(string ruta)
        {
            try
            {
                if (File.Exists(ruta)) File.Delete(ruta);
            }
            catch (Exception)
            {
            }
        }

        static (int codigo, string salida) Corre(string programa, params string[] args)
        {
            try
            {
                var psi = new ProcessStartInfo(programa, Argumentos.Une(args))
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                using (var p = Process.Start(psi))
                {
                    var salida = p.StandardOutput.ReadToEndAsync();
                    var error = p.StandardError.ReadToEndAsync();
                    p.WaitForExit(30000);
                    return (p.HasExited ? p.ExitCode : -1, (salida.Result + error.Result).Trim());
                }
            }
            catch (Exception e)
            {
                return (-1, e.Message);
            }
        }
    }
}
