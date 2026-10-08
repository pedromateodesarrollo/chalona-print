using System;
using System.Drawing;
using System.IO;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace PrintServer
{
    /// <summary>
    /// print-server para Windows: la ventana, el icono de la bandeja y el
    /// servicio son el mismo .exe, con el agente (Dart) metido dentro.
    ///
    /// <code>
    ///   print-server.exe                     la ventana
    ///   print-server.exe --bandeja           el icono junto al reloj
    ///   print-server.exe --servicio          lo que arranca Windows (no a mano)
    ///
    ///   Con permiso de administrador (la ventana los pide sola):
    ///   print-server.exe --instalar [--hub URL --llave cpk_... [--nombre X]]
    ///   print-server.exe --desconectar
    ///   print-server.exe --iniciar
    ///   print-server.exe --desinstalar
    ///   …y todos aceptan --resultado ARCHIVO, donde dejan el mensaje final.
    /// </code>
    /// </summary>
    static class Programa
    {
        [STAThread]
        static int Main(string[] args)
        {
            var a = Argumentos.Lee(args);
            switch (a.Orden)
            {
                case "--servicio":
                    ServiceBase.Run(new ServicioAgente());
                    return 0;

                case "--instalar":
                case "--desconectar":
                case "--iniciar":
                case "--desinstalar":
                    return Accion(a);

                case "--bandeja":
                    return AbreBandeja();

                case "--captura":
                    // Para la prueba automática: pinta la ventana en un PNG.
                    return AbreVentana(a.Opcion("archivo"));

                default:
                    return AbreVentana(null);
            }
        }

        static void PreparaInterfaz()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
        }

        static int AbreVentana(string captura)
        {
            PreparaInterfaz();
            var v = new Ventana();
            if (!string.IsNullOrEmpty(captura)) v.CapturaAlListo(captura);
            Application.Run(v);
            return 0;
        }

        static int AbreBandeja()
        {
            // Un icono por sesión: si ya hay uno, no se pone otro.
            using (var unico = new Mutex(true, @"Local\print-server-bandeja", out var nuevo))
            {
                if (!nuevo) return 0;
                PreparaInterfaz();
                Application.Run(new Bandeja());
                GC.KeepAlive(unico);
            }
            return 0;
        }

        static int Accion(Argumentos a)
        {
            var registro = new RegistroArchivo(Rutas.Registro);
            int.TryParse(a.Opcion("padre"), out var padre);
            string mensaje;
            int codigo;
            try
            {
                if (!Instalacion.EsAdministrador())
                    throw new InvalidOperationException("Hace falta permiso de administrador.");
                switch (a.Orden)
                {
                    case "--instalar":
                        mensaje = Instalacion.Instala(Datos(a), padre, registro);
                        break;
                    case "--desconectar":
                        mensaje = Instalacion.Desconecta(registro);
                        break;
                    case "--iniciar":
                        mensaje = Instalacion.Inicia();
                        break;
                    default:
                        mensaje = Instalacion.Desinstala(padre, registro);
                        break;
                }
                codigo = 0;
            }
            catch (Exception e)
            {
                mensaje = e.Message;
                codigo = 1;
                if (a.Orden != "--desinstalar") registro.Escribe("instalar", "falló: " + e.Message);
            }

            var resultado = a.Opcion("resultado");
            if (resultado.Length > 0)
            {
                try
                {
                    File.WriteAllText(resultado, mensaje, new UTF8Encoding(false));
                }
                catch (Exception)
                {
                }
            }
            return codigo;
        }

        /// <summary>Los datos vienen de la ventana (archivo) o de un script (opciones).</summary>
        static DatosConexion Datos(Argumentos a)
        {
            if (a.Opcion("datos").Length > 0) return Elevar.LeeDatos(a.Opcion("datos"));
            if (a.Opcion("hub").Length == 0 && a.Opcion("llave").Length == 0) return null;
            return new DatosConexion { Hub = a.Opcion("hub"), Llave = a.Opcion("llave"), Nombre = a.Opcion("nombre") };
        }
    }

    static class Recursos
    {
        public static Icon Icono(Size tamano)
        {
            using (var s = typeof(Recursos).Assembly.GetManifestResourceStream("icono.ico"))
                return s == null ? SystemIcons.Application : new Icon(s, tamano);
        }
    }
}
