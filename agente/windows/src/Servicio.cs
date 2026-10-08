using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace PrintServer
{
    /// <summary>
    /// El servicio de Windows: arranca el agente y lo vuelve a levantar si se cae.
    ///
    /// El agente (Dart) no puede ser un servicio él mismo: el Administrador de
    /// servicios llama desde otro hilo y espera respuesta, y Dart corre en uno
    /// solo. Por eso el servicio es esto, en C#, y el agente corre como un
    /// proceso hijo normal. Arranca con Windows sin que nadie inicie sesión.
    ///
    /// El agente va dentro de un «job» de Windows que muere con el servicio: si
    /// el servicio se cae o lo matan, no queda un agente huérfano conectado al
    /// hub con la misma credencial que el siguiente.
    /// </summary>
    sealed class ServicioAgente : ServiceBase
    {
        readonly ManualResetEvent _parar = new ManualResetEvent(false);
        readonly object _cerrojo = new object();
        readonly RegistroArchivo _registro = new RegistroArchivo(Rutas.Registro);
        Thread _hilo;
        Process _agente;
        Trabajo _trabajo;

        public ServicioAgente()
        {
            ServiceName = Rutas.Servicio;
            CanStop = true;
            CanShutdown = true;
            AutoLog = false;
        }

        protected override void OnStart(string[] args)
        {
            _registro.Escribe("servicio", $"arranca la {Rutas.Version}");
            _hilo = new Thread(Bucle) { IsBackground = true, Name = "supervisor" };
            _hilo.Start();
        }

        protected override void OnStop() => Detiene();

        protected override void OnShutdown() => Detiene();

        void Detiene()
        {
            _parar.Set();
            MataAgente();
            _hilo?.Join(10000);
            _registro.Escribe("servicio", "detenido");
        }

        void Bucle()
        {
            var espera = TimeSpan.FromSeconds(5);
            var avisadoSinConfig = false;
            while (!_parar.WaitOne(0))
            {
                var config = ConfigAgente.Lee(Rutas.Config);
                if (config == null || !config.Configurado)
                {
                    // Desconectado desde la ventana: se espera a que alguien vuelva a
                    // conectar, sin reintentar un agente que solo diría «sin configurar».
                    if (!avisadoSinConfig) _registro.Escribe("servicio", "sin conectar a un hub: espero");
                    avisadoSinConfig = true;
                    if (_parar.WaitOne(5000)) break;
                    continue;
                }
                avisadoSinConfig = false;

                if (!File.Exists(Rutas.Agente))
                {
                    _registro.Escribe("servicio", $"falta {Rutas.Agente}: reinstala desde la ventana");
                    if (_parar.WaitOne(60000)) break;
                    continue;
                }

                var inicio = DateTime.UtcNow;
                int codigo;
                try
                {
                    codigo = CorreAgente();
                }
                catch (Exception e)
                {
                    _registro.Escribe("servicio", "no pude arrancar el agente: " + e.Message);
                    codigo = -1;
                }
                if (_parar.WaitOne(0)) break;

                // Si aguantó un buen rato, el próximo fallo es nuevo y no un bucle.
                if (DateTime.UtcNow - inicio > TimeSpan.FromMinutes(2)) espera = TimeSpan.FromSeconds(5);
                _registro.Escribe("servicio", $"el agente terminó (código {codigo}); lo vuelvo a arrancar en {espera.TotalSeconds:0} s");
                if (_parar.WaitOne(espera)) break;
                espera = TimeSpan.FromSeconds(Math.Min(espera.TotalSeconds * 2, 60));
            }
        }

        int CorreAgente()
        {
            var psi = new ProcessStartInfo(Rutas.Agente, "correr")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Rutas.Programa,
            };
            psi.EnvironmentVariables["PRINT_AGENTE_MODO"] = "servicio";
            psi.EnvironmentVariables["PRINT_AGENTE_UTF8"] = "1";

            var p = new Process { StartInfo = psi };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) _registro.Linea(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) _registro.Linea(e.Data); };
            p.Start();
            lock (_cerrojo)
            {
                _agente = p;
                _trabajo?.Dispose();
                _trabajo = null;
                try
                {
                    _trabajo = new Trabajo();
                    _trabajo.Asigna(p);
                }
                catch (Exception e)
                {
                    // El agente ya está corriendo: lanzar la excepción lo dejaría
                    // huérfano y el bucle arrancaría otro. Sin job sigue valiendo
                    // el Kill de MataAgente; solo se pierde la red si el servicio
                    // muere de golpe.
                    _registro.Escribe("servicio", "el agente corre sin job: " + e.Message);
                }
            }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            while (!p.WaitForExit(1000))
            {
                if (_parar.WaitOne(0))
                {
                    MataAgente();
                    break;
                }
            }
            // Sin este segundo WaitForExit las últimas líneas de la salida se pierden.
            p.WaitForExit(5000);
            var codigo = p.HasExited ? p.ExitCode : -1;
            lock (_cerrojo)
            {
                _agente = null;
                p.Dispose();
            }
            return codigo;
        }

        void MataAgente()
        {
            lock (_cerrojo)
            {
                try
                {
                    if (_agente != null && !_agente.HasExited) _agente.Kill();
                }
                catch (Exception)
                {
                    // Ya había terminado: no hay nada que matar.
                }
                // Cerrar el job se lleva por delante lo que el agente hubiera
                // lanzado (el ayudante de PDF, por ejemplo).
                _trabajo?.Dispose();
                _trabajo = null;
            }
        }
    }

    /// <summary>
    /// El registro del servicio en disco: <c>ProgramData\print-server\agente.log</c>.
    ///
    /// Corriendo como servicio no hay consola, y sin esto un agente que se cae
    /// al arrancar no deja ni una línea en ninguna parte (pasó con la 0.2.0).
    /// La ventana lo enseña cuando el agente no contesta.
    /// </summary>
    sealed class RegistroArchivo
    {
        const long Tope = 2 * 1024 * 1024;
        readonly string _ruta;
        readonly object _cerrojo = new object();
        static readonly Encoding Utf8 = new UTF8Encoding(false);

        public RegistroArchivo(string ruta) { _ruta = ruta; }

        public void Escribe(string etiqueta, string mensaje) =>
            Linea($"{DateTime.Now:yyyy-MM-ddTHH:mm:ss.fff} info [{etiqueta}] {mensaje}");

        public void Linea(string linea)
        {
            lock (_cerrojo)
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(_ruta));
                    var f = new FileInfo(_ruta);
                    if (f.Exists && f.Length > Tope)
                    {
                        var viejo = _ruta + ".1";
                        if (File.Exists(viejo)) File.Delete(viejo);
                        File.Move(_ruta, viejo);
                    }
                    File.AppendAllText(_ruta, linea + "\r\n", Utf8);
                }
                catch (Exception)
                {
                    // Un registro que no se puede escribir no puede tumbar al servicio.
                }
            }
        }

        /// <summary>Las últimas líneas, para la ventana.</summary>
        public static string[] Ultimas(string ruta, int cuantas)
        {
            try
            {
                if (!File.Exists(ruta)) return new string[0];
                using (var f = new FileStream(ruta, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    // Basta con el final del archivo: no hace falta leer 2 MB cada vez.
                    var desde = Math.Max(0, f.Length - 64 * 1024);
                    f.Seek(desde, SeekOrigin.Begin);
                    using (var r = new StreamReader(f, Encoding.UTF8))
                    {
                        var lineas = r.ReadToEnd().Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                        var n = Math.Min(cuantas, lineas.Length);
                        var salida = new string[n];
                        Array.Copy(lineas, lineas.Length - n, salida, 0, n);
                        return salida;
                    }
                }
            }
            catch (Exception)
            {
                return new string[0];
            }
        }
    }

    /// <summary>
    /// Un «job object» de Windows con <c>KILL_ON_JOB_CLOSE</c>: los procesos que
    /// se le asignan mueren cuando se cierra, aunque sea porque el servicio se
    /// cayó sin avisar.
    /// </summary>
    sealed class Trabajo : IDisposable
    {
        IntPtr _asa;

        public Trabajo()
        {
            _asa = CreateJobObject(IntPtr.Zero, null);
            if (_asa == IntPtr.Zero) throw new Win32Exception();
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            var largo = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            var ptr = Marshal.AllocHGlobal(largo);
            try
            {
                Marshal.StructureToPtr(info, ptr, false);
                if (!SetInformationJobObject(_asa, 9 /* ExtendedLimitInformation */, ptr, (uint)largo))
                    throw new Win32Exception();
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }
        }

        public void Asigna(Process p)
        {
            if (!AssignProcessToJobObject(_asa, p.Handle)) throw new Win32Exception();
        }

        public void Dispose()
        {
            if (_asa != IntPtr.Zero) CloseHandle(_asa);
            _asa = IntPtr.Zero;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr atributos, string nombre);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int clase, IntPtr info, uint largo);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proceso);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr asa);
    }
}
