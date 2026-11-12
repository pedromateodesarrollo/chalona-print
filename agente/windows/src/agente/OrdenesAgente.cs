using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace PrintServer.Agente
{
    /// <summary>
    /// Las órdenes del agente, las mismas del agente de Dart:
    ///
    /// <code>
    ///   print-server-agente correr        trabaja en primer plano (lo que arranca el servicio)
    ///   print-server-agente configurar    --hub URL --llave cpk_... [--nombre X]
    ///   print-server-agente impresoras    lo que ve del sistema
    ///   print-server-agente probar        --impresora X [--protocolo driver|zpl|epl|dp|texto]
    ///   print-server-agente imprimir      --impresora X --archivo RUTA [--formato pdf|raw|…] [--copias N]
    ///   print-server-agente --version
    /// </code>
    ///
    /// El agente va dentro de print-server.exe; la instalación deja una copia
    /// llamada print-server-agente.exe para que el servicio lo arranque como un
    /// proceso aparte (si se cae, el servicio lo levanta) y se reconozca en el
    /// Administrador de tareas.
    /// </summary>
    static class OrdenesAgente
    {
        static readonly HashSet<string> Ordenes = new HashSet<string>
        {
            "correr", "configurar", "impresoras", "probar", "imprimir", "--version", "ayuda", "--ayuda", "-h",
        };

        public static bool Es(string[] args) => args.Length > 0 && Ordenes.Contains(args[0].Trim().ToLowerInvariant());

        const string Ayuda = @"print-server-agente — imprime en esta computadora lo que le manda el hub.

  correr               Trabaja en primer plano (es lo que hace el servicio)
  configurar           --hub <url> --llave <cpk_...> [--nombre <texto>]
  impresoras           Enseña lo que ve del sistema
  probar               --impresora <nombre> [--protocolo driver|zpl|epl|dp|texto]:
                       la página de prueba, en el protocolo de esa impresora
  imprimir             --impresora <nombre> --archivo <ruta> [--formato pdf|raw|…]
                       [--copias N]: manda un archivo tal cual

Para instalarlo como servicio de Windows, abre print-server.exe (sin argumentos).";

        public static int Corre(string[] args)
        {
            PreparaConsola();
            var a = Argumentos.Lee(args);
            Log.Salida = Console.Out;
            switch (a.Orden)
            {
                case "--version":
                    Console.Out.WriteLine($"print-server-agente {VersionAgente.Numero} ({Equipo.Arquitectura()})");
                    return 0;
                case "configurar":
                    return Configurar(a);
                case "correr":
                    return Correr();
                case "impresoras":
                    return Impresoras();
                case "probar":
                    return Probar(a.Opcion("impresora"), a.Opcion("protocolo"));
                case "imprimir":
                    return Imprimir(a);
                default:
                    Console.Out.WriteLine(Ayuda);
                    return 0;
            }
        }

        static int Configurar(Argumentos a)
        {
            var config = ConfigLocal.Carga();
            try
            {
                Alta.Registra(config, a.Opcion("hub"), a.Opcion("llave"), a.Opcion("nombre"));
                Console.Out.WriteLine($"Conectado a {config.Hub} como agente {config.Agente}.");
                return 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(Alta.Mensaje(e));
                return 1;
            }
        }

        /// <summary>El modo de trabajo: panel local + WebSocket con el hub, hasta que lo paren.</summary>
        static int Correr()
        {
            var config = ConfigLocal.Carga();
            if (config.Ilegible)
            {
                Console.Error.WriteLine($"No puedo leer la configuración ({ConfigLocal.RutaPorDefecto()}). " +
                                        "Lleva la credencial del agente: abre la consola como administrador.");
                return 77;
            }
            if (!config.Configurado)
            {
                Console.Error.WriteLine("Esta computadora no está conectada a ningún hub. Abre print-server.exe, o usa: " +
                                        "print-server-agente configurar --hub <url> --llave <cpk_...>");
                return 78;
            }

            var cliente = new Cliente(config, Drivers.Elige(config), Hechos.Abre(ConfigLocal.RutaPorDefecto()));
            var panel = new PanelLocal(config, cliente);
            try
            {
                panel.Arranca();
            }
            catch (Exception e)
            {
                // Que el panel no pueda abrir su puerto no puede impedir imprimir.
                Log.Aviso("panel", "no pude abrir el panel local: " + e.Message);
            }
            Console.CancelKeyPress += (s, e) =>
            {
                e.Cancel = true;
                Log.Info("agente", "parando…");
                cliente.Detiene();
                panel.Detiene();
            };
            Log.Info("agente", $"agente {config.Agente} · hub {config.Hub} · {VersionAgente.Numero} {Equipo.Arquitectura()}");
            cliente.Corre();
            return 0;
        }

        static int Impresoras()
        {
            var driver = Drivers.Elige(ConfigLocal.Carga());
            var lista = driver.Inventario();
            if (lista.Count == 0)
            {
                Console.Out.WriteLine($"Ninguna impresora (driver: {driver.Nombre}).");
                return 0;
            }
            foreach (var i in lista)
            {
                var identidad = string.Join(" · ", new[]
                {
                    i.Fabricante, i.Conexion.ToUpperInvariant(), i.Serie.Length > 0 ? "serie " + i.Serie : "",
                }.Where(x => x.Length > 0));
                Console.Out.WriteLine($"{i.Sistema.PadRight(28)} {i.Estado.PadRight(10)} {identidad.PadRight(34)}" +
                                      $"{(i.Predeterminada ? "*" : " ")} {i.Detalle}");
            }
            return 0;
        }

        /// <summary>La misma página de prueba que mandan el hub y la ventana.</summary>
        static int Probar(string impresora, string protocolo)
        {
            var config = ConfigLocal.Carga();
            var driver = Drivers.Elige(config);
            var lista = driver.Inventario();
            var destino = impresora;
            if (destino.Length == 0)
                destino = (lista.FirstOrDefault(i => i.Predeterminada) ?? lista.FirstOrDefault())?.Sistema ?? "";
            if (destino.Length == 0)
            {
                Console.Error.WriteLine("No hay impresoras. Usa --impresora <nombre>.");
                return 1;
            }
            var ficha = lista.LastOrDefault(i => i.Sistema == destino);
            try
            {
                var p = Prueba.Imprime(driver, ficha, destino, protocolo.Length > 0 ? protocolo : null, config.Nombre);
                Console.Out.WriteLine($"Mandada a «{destino}» (por {p}).");
                return 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e.Message);
                return 1;
            }
        }

        /// <summary>Un archivo tal cual, sin hub: así se prueba el PDF por el driver.</summary>
        static int Imprimir(Argumentos a)
        {
            var impresora = a.Opcion("impresora");
            var archivo = a.Opcion("archivo");
            if (impresora.Length == 0 || archivo.Length == 0 || !File.Exists(archivo))
            {
                Console.Error.WriteLine("Uso: imprimir --impresora <nombre> --archivo <ruta> [--formato pdf]");
                return 64;
            }
            var formato = a.Opcion("formato");
            if (formato.Length == 0) formato = archivo.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? "pdf" : "raw";
            int.TryParse(a.Opcion("copias"), out var copias);
            try
            {
                Drivers.Elige(ConfigLocal.Carga()).Imprime(new TrabajoLocal
                {
                    Id = -1,
                    Impresora = impresora,
                    Formato = formato,
                    Nombre = Path.GetFileName(archivo),
                    Contenido = File.ReadAllBytes(archivo),
                    Copias = copias > 0 ? copias : 1,
                });
                Console.Out.WriteLine($"Mandado a «{impresora}» ({formato}).");
                return 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e.Message);
                return 1;
            }
        }

        // ---------------------------------------------------------------- consola

        /// <summary>
        /// Es un programa de ventanas: no trae consola. Si la salida va a un archivo o
        /// a una tubería (el servicio la recoge así) se escribe ahí; si no, se pega a
        /// la consola desde donde se lanzó. Con <c>PRINT_AGENTE_UTF8=1</c> sale en
        /// UTF-8, que es como la lee el servicio: «Conexión» llega como «Conexión».
        /// </summary>
        static void PreparaConsola()
        {
            var h = GetStdHandle(StdOutput);
            var tipo = h == IntPtr.Zero || h == new IntPtr(-1) ? 0u : GetFileType(h);
            var consola = false;
            if (tipo == 0) consola = AttachConsole(AttachParentProcess);
            Encoding enc;
            if (Environment.GetEnvironmentVariable("PRINT_AGENTE_UTF8") == "1")
            {
                enc = new UTF8Encoding(false);
            }
            else
            {
                try
                {
                    enc = consola || tipo == 2 ? Console.OutputEncoding : new UTF8Encoding(false);
                }
                catch (Exception)
                {
                    enc = new UTF8Encoding(false);
                }
            }
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), enc) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(), enc) { AutoFlush = true });
            if (consola) Console.Out.WriteLine();
        }

        const int StdOutput = -11;
        const int AttachParentProcess = -1;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int cual);

        [DllImport("kernel32.dll")]
        static extern uint GetFileType(IntPtr h);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AttachConsole(int proceso);
    }
}
