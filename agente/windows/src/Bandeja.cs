using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace PrintServer
{
    /// <summary>
    /// El icono junto al reloj. Arranca al iniciar sesión cualquiera (lo pone la
    /// instalación en el registro) y abre la ventana con un clic.
    ///
    /// No imprime ni es necesario para imprimir: eso lo hace el servicio, que
    /// corre aunque nadie haya iniciado sesión. El icono es para que quien está
    /// sentado ahí vea de un vistazo si la computadora sigue conectada.
    /// </summary>
    sealed class Bandeja : ApplicationContext
    {
        readonly NotifyIcon _icono;
        readonly Control _hilo = new Control();
        readonly System.Windows.Forms.Timer _reloj = new System.Windows.Forms.Timer { Interval = 10000 };
        Ventana _ventana;
        bool _consultando;

        public Bandeja()
        {
            // Un control sin ventana visible, solo para volver al hilo de la
            // interfaz desde la consulta al agente.
            _hilo.CreateControl();

            var menu = new ContextMenuStrip();
            var abrir = menu.Items.Add("Abrir print-server", null, (s, e) => Abre());
            abrir.Font = new Font(abrir.Font, FontStyle.Bold);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quitar este icono", null, (s, e) => Sale());

            _icono = new NotifyIcon
            {
                Icon = Recursos.Icono(SystemInformation.SmallIconSize),
                Text = "print-server",
                ContextMenuStrip = menu,
                Visible = true,
            };
            _icono.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left) Abre();
            };

            _reloj.Tick += (s, e) => Consulta();
            _reloj.Start();
            Consulta();
        }

        void Abre()
        {
            if (_ventana == null || _ventana.IsDisposed)
            {
                _ventana = new Ventana();
                _ventana.FormClosed += (s, e) => _ventana = null;
                _ventana.Show();
                return;
            }
            if (_ventana.WindowState == FormWindowState.Minimized) _ventana.WindowState = FormWindowState.Normal;
            _ventana.Activate();
        }

        void Consulta()
        {
            if (_consultando) return;
            _consultando = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var config = ConfigAgente.Lee(Rutas.Config);
                var estado = Panel.Estado(config?.PuertoPanel ?? 7717);
                string texto;
                if (estado == null) texto = config != null && config.Configurado ? "el agente no responde" : "sin conectar";
                else if (!estado.Configurado) texto = "sin conectar";
                else texto = estado.Conectado ? "conectado" : "sin conexión con el hub";
                try
                {
                    _hilo.BeginInvoke((Action)(() =>
                    {
                        _consultando = false;
                        // NotifyIcon no acepta más de 63 caracteres.
                        var t = "print-server · " + texto;
                        _icono.Text = t.Length > 63 ? t.Substring(0, 63) : t;
                    }));
                }
                catch (InvalidOperationException)
                {
                }
            });
        }

        void Sale()
        {
            _reloj.Stop();
            _icono.Visible = false;
            _icono.Dispose();
            ExitThread();
        }
    }
}
