using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace PrintServer
{
    /// <summary>
    /// La ventana de print-server: lo que se abre con doble clic al descargarlo,
    /// desde el menú Inicio o desde el icono junto al reloj.
    ///
    /// Sustituye al asistente en el navegador de la 0.2. Sin configurar sirve
    /// para conectar; conectada, enseña cómo va el agente. Nunca corre como
    /// administrador: lo que lo necesita (conectar, instalar, desinstalar) se
    /// pide para esa acción y Windows enseña su aviso de permiso. Por eso esos
    /// botones llevan el escudo.
    /// </summary>
    sealed class Ventana : Form
    {
        static readonly Color Verde = Color.FromArgb(22, 163, 74);
        static readonly Color Rojo = Color.FromArgb(220, 38, 38);
        static readonly Color Ambar = Color.FromArgb(217, 119, 6);
        const string HubPorDefecto = "https://print.chalonasoft.com";

        readonly Label _version = new Label();
        readonly Label _estado = new Label();
        readonly TextBox _hub = new TextBox();
        readonly TextBox _llave = new TextBox();
        readonly TextBox _nombre = new TextBox();
        readonly Button _conexion = new Button();
        readonly Label _eHub = Valor();
        readonly Label _eAgente = Valor();
        readonly Label _eDesde = Valor();
        readonly Label _eTrabajos = Valor();
        readonly Label _eError = Valor();
        readonly ListView _impresoras = new ListView();
        readonly Button _probar = new Button();
        readonly Label _arranque = new Label();
        readonly Button _accion = new Button();
        readonly Button _desinstalar = new Button();
        readonly TextBox _registro = new TextBox();
        readonly ToolTip _ayuda = new ToolTip();
        readonly System.Windows.Forms.Timer _reloj = new System.Windows.Forms.Timer { Interval = 2500 };

        Situacion _actual;
        bool _consultando;
        bool _ocupado;
        string _progreso = "";
        bool? _conectadaMostrada;
        string _firmaImpresoras;
        string _firmaRegistro;
        string _captura;
        DateTime _inicioCaptura;

        public Ventana()
        {
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = SystemFonts.MessageBoxFont;
            Text = "print-server";
            Icon = Recursos.Icono(new Size(32, 32));
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(760, 900);
            MinimumSize = new Size(600, 660);

            var raiz = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 6,
                Padding = new Padding(14, 10, 14, 14),
            };
            raiz.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            raiz.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            raiz.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            raiz.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            raiz.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
            raiz.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            raiz.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
            raiz.Controls.Add(Cabecera(), 0, 0);
            raiz.Controls.Add(Grupo("Conexión con el hub", Conexion(), true), 0, 1);
            raiz.Controls.Add(Grupo("Estado", Estado(), true), 0, 2);
            raiz.Controls.Add(Grupo("Impresoras", Impresoras(), false), 0, 3);
            raiz.Controls.Add(Grupo("Arranque con Windows", Arranque(), true), 0, 4);
            raiz.Controls.Add(Grupo("Registro", Registro(), false), 0, 5);
            Controls.Add(raiz);

            _reloj.Tick += (s, e) => Refresca();
            FormClosed += (s, e) => _reloj.Stop();
            ResumeLayout(true);
        }

        /// <summary>Modo de la prueba automática: cuando haya datos, pinta la ventana en un PNG y se cierra.</summary>
        public void CapturaAlListo(string archivo)
        {
            _captura = archivo;
            _inicioCaptura = DateTime.UtcNow;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            foreach (var b in new[] { _conexion, _accion, _desinstalar }) Escudo(b);
            Pista(_hub, HubPorDefecto);
            Pista(_llave, "cpk_… (se crea en el hub, en «Instalar agente»)");
            Refresca();
            _reloj.Start();
        }

        // -------------------------------------------------------------- armado

        Control Cabecera()
        {
            var fila = new FlowLayoutPanel
            {
                AutoSize = true,
                WrapContents = false,
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 0, 0, 8),
            };
            var titulo = new Label
            {
                Text = "print-server",
                AutoSize = true,
                Font = new Font(Font.FontFamily, 16F, FontStyle.Bold),
                Margin = new Padding(0, 0, 10, 0),
            };
            _version.AutoSize = true;
            _version.ForeColor = SystemColors.GrayText;
            _version.Font = new Font(Font.FontFamily, 10F);
            _version.Margin = new Padding(0, 10, 10, 0);
            _version.Text = "v" + Rutas.Version;
            _estado.AutoSize = true;
            _estado.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
            _estado.Margin = new Padding(0, 8, 0, 0);
            fila.Controls.AddRange(new Control[] { titulo, _version, _estado });
            return fila;
        }

        static GroupBox Grupo(string titulo, Control contenido, bool ajustado)
        {
            var g = new GroupBox
            {
                Text = titulo,
                Dock = DockStyle.Fill,
                Padding = new Padding(10, 6, 10, 8),
                Margin = new Padding(0, 0, 0, 8),
            };
            if (ajustado)
            {
                g.AutoSize = true;
                g.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            }
            contenido.Dock = DockStyle.Fill;
            g.Controls.Add(contenido);
            return g;
        }

        static TableLayoutPanel Tabla(int columnas)
        {
            var t = new TableLayoutPanel { ColumnCount = columnas, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            for (var i = 1; i < columnas; i++) t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            return t;
        }

        static Label Etiqueta(string texto, bool gris) => new Label
        {
            Text = texto,
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            ForeColor = gris ? SystemColors.GrayText : SystemColors.ControlText,
            Margin = new Padding(0, 4, 16, 4),
        };

        static Label Valor() => new Label
        {
            AutoSize = false,
            AutoEllipsis = true,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Height = 22,
            Margin = new Padding(0, 1, 0, 1),
            Text = "—",
        };

        Control Conexion()
        {
            var t = Tabla(2);
            foreach (var (texto, caja) in new[] { ("Hub", _hub), ("Llave de API", _llave), ("Esta computadora", _nombre) })
            {
                caja.Dock = DockStyle.Fill;
                caja.Margin = new Padding(0, 3, 0, 3);
                t.Controls.Add(Etiqueta(texto, false));
                t.Controls.Add(caja);
            }
            _llave.UseSystemPasswordChar = true;
            _conexion.Text = "Conectar";
            _conexion.Margin = new Padding(0, 8, 0, 2);
            _conexion.Click += (s, e) => ConexionClic();
            t.Controls.Add(new Label { AutoSize = true });
            t.Controls.Add(_conexion);
            return t;
        }

        Control Estado()
        {
            var t = Tabla(2);
            foreach (var (texto, valor) in new[]
            {
                ("Hub", _eHub), ("Agente", _eAgente), ("Conectado desde", _eDesde),
                ("Trabajos", _eTrabajos), ("Último error", _eError),
            })
            {
                t.Controls.Add(Etiqueta(texto, true));
                t.Controls.Add(valor);
            }
            _eError.ForeColor = Rojo;
            _eError.Text = "";
            return t;
        }

        Control Impresoras()
        {
            var t = new TableLayoutPanel { ColumnCount = 1, RowCount = 2 };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            _impresoras.View = View.Details;
            _impresoras.FullRowSelect = true;
            _impresoras.HideSelection = false;
            _impresoras.MultiSelect = false;
            _impresoras.HeaderStyle = ColumnHeaderStyle.Nonclickable;
            _impresoras.Dock = DockStyle.Fill;
            _impresoras.Columns.Add("Impresora", 300);
            _impresoras.Columns.Add("Estado", 110);
            _impresoras.Columns.Add("Detalle", 200);
            _impresoras.Resize += (s, e) => AjustaColumnas();
            _impresoras.SelectedIndexChanged += (s, e) => ActualizaBotones();
            _impresoras.DoubleClick += (s, e) => ProbarClic();

            _probar.Text = "Imprimir página de prueba";
            _probar.AutoSize = true;
            _probar.Anchor = AnchorStyles.Right;
            _probar.Margin = new Padding(0, 8, 0, 0);
            _probar.Click += (s, e) => ProbarClic();
            _ayuda.SetToolTip(_probar, "Sale en el idioma de esa impresora: ZPL, EPL o texto.");

            t.Controls.Add(_impresoras, 0, 0);
            t.Controls.Add(_probar, 0, 1);
            return t;
        }

        Control Arranque()
        {
            var t = Tabla(2);
            t.ColumnStyles[0] = new ColumnStyle(SizeType.Percent, 100);
            t.ColumnStyles[1] = new ColumnStyle(SizeType.AutoSize);

            _arranque.AutoSize = false;
            _arranque.Dock = DockStyle.Fill;
            _arranque.Height = 40;
            _arranque.TextAlign = ContentAlignment.MiddleLeft;
            _arranque.Margin = new Padding(0, 2, 12, 2);

            var botones = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Anchor = AnchorStyles.Right };
            _accion.Margin = new Padding(0, 4, 8, 4);
            _accion.Click += (s, e) => AccionClic();
            _desinstalar.Text = "Desinstalar";
            _desinstalar.Margin = new Padding(0, 4, 0, 4);
            _desinstalar.Click += (s, e) => DesinstalarClic();
            botones.Controls.Add(_accion);
            botones.Controls.Add(_desinstalar);

            t.Controls.Add(_arranque, 0, 0);
            t.Controls.Add(botones, 1, 0);
            return t;
        }

        Control Registro()
        {
            _registro.Multiline = true;
            _registro.ReadOnly = true;
            _registro.WordWrap = false;
            _registro.ScrollBars = ScrollBars.Vertical;
            _registro.BackColor = SystemColors.Window;
            _registro.Font = new Font("Consolas", 8.25F);
            return _registro;
        }

        void AjustaColumnas()
        {
            var ancho = _impresoras.ClientSize.Width;
            if (ancho <= 0 || _impresoras.Columns.Count < 3) return;
            _impresoras.Columns[0].Width = (int)(ancho * 0.46);
            _impresoras.Columns[1].Width = (int)(ancho * 0.18);
            _impresoras.Columns[2].Width = ancho - _impresoras.Columns[0].Width - _impresoras.Columns[1].Width - 4;
        }

        // ------------------------------------------------------------ refresco

        void Refresca()
        {
            if (_consultando || IsDisposed) return;
            _consultando = true;
            var propia = Rutas.Version;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Situacion s = null;
                try
                {
                    s = Lee(propia);
                }
                catch (Exception)
                {
                    // Se reintenta en el próximo tic.
                }
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        _consultando = false;
                        if (s != null) Pinta(s);
                    }));
                }
                catch (InvalidOperationException)
                {
                    // La ventana ya se cerró.
                }
            });
        }

        static Situacion Lee(string propia)
        {
            var s = new Situacion
            {
                VersionPropia = propia,
                Config = ConfigAgente.Lee(Rutas.Config) ?? ConfigAgente.Lee(Rutas.ConfigVieja),
                Servicio = Instalacion.Servicio(),
                VersionInstalada = Instalacion.VersionInstalada(),
                ServiciosViejos = Instalacion.ServiciosViejosPresentes(),
            };
            s.Agente = Panel.Estado(s.Config?.PuertoPanel ?? 7717);
            if (s.Agente == null) s.RegistroEnDisco = RegistroArchivo.Ultimas(Rutas.Registro, 60);
            return s;
        }

        void Pinta(Situacion s)
        {
            _actual = s;

            var (cabecera, tono) = s.Cabecera();
            _estado.Text = "● " + cabecera;
            _estado.ForeColor = ColorDe(tono);

            // Conexión. Los campos solo se rellenan al cambiar de estado, para no
            // pisar lo que alguien está escribiendo.
            var conectada = s.Conectada;
            if (_conectadaMostrada != conectada)
            {
                _conectadaMostrada = conectada;
                _llave.Text = "";
                if (!conectada)
                {
                    _hub.Text = s.Hub.Length > 0 ? s.Hub : HubPorDefecto;
                    _nombre.Text = Environment.MachineName;
                }
                _hub.Enabled = _llave.Enabled = _nombre.Enabled = !conectada;
                _conexion.Text = conectada ? "Desconectar" : "Conectar";
                AjustaBoton(_conexion);
            }
            if (conectada)
            {
                _hub.Text = s.Hub;
                _nombre.Text = s.Nombre;
            }

            // Estado.
            _eHub.Text = s.Hub.Length > 0 ? s.Hub : "—";
            var a = s.Agente;
            if (a != null)
            {
                _eAgente.Text = Textos.Agente(a);
                _eDesde.Text = a.Conectado && a.ConectadoDesde.HasValue ? Fechas.Escribe(a.ConectadoDesde.Value) : "—";
                _eTrabajos.Text = Textos.Trabajos(a);
                _eError.Text = a.UltimoError;
            }
            else
            {
                _eAgente.Text = s.Config != null && s.Config.Agente > 0
                    ? $"{s.Config.Agente} · {s.Config.Nombre} (no está corriendo)"
                    : (conectada ? "no está corriendo" : "—");
                _eDesde.Text = "—";
                _eTrabajos.Text = "—";
                _eError.Text = "";
            }
            _ayuda.SetToolTip(_eError, _eError.Text);
            _ayuda.SetToolTip(_eAgente, _eAgente.Text);

            PintaImpresoras(a?.Impresoras ?? new List<Impresora>());

            // Arranque con Windows.
            var (texto, accion, desinstalar) = s.Arranque();
            _arranque.Text = _ocupado ? _progreso : texto;
            _accion.Tag = accion;
            _accion.Visible = accion != AccionArranque.Ninguna;
            _accion.Text = accion == AccionArranque.Instalar ? "Instalar"
                : accion == AccionArranque.Actualizar ? "Actualizar"
                : "Iniciar";
            AjustaBoton(_accion);
            _desinstalar.Visible = desinstalar;
            AjustaBoton(_desinstalar);

            // Registro.
            var lineas = s.Registro();
            var firma = lineas.Count + "|" + (lineas.Count > 0 ? lineas[lineas.Count - 1] : "");
            if (firma != _firmaRegistro)
            {
                _firmaRegistro = firma;
                _registro.Text = string.Join("\r\n", lineas);
                _registro.SelectionStart = _registro.TextLength;
                _registro.ScrollToCaret();
            }

            ActualizaBotones();
            IntentaCaptura(s);
        }

        void PintaImpresoras(List<Impresora> lista)
        {
            var firma = string.Join("\n", lista.Select(i => $"{i.Sistema}|{i.Estado}|{i.Detalle}|{i.Predeterminada}"));
            if (firma == _firmaImpresoras) return;
            _firmaImpresoras = firma;

            var elegida = _impresoras.SelectedItems.Count > 0 ? _impresoras.SelectedItems[0].Tag as string : null;
            _impresoras.BeginUpdate();
            _impresoras.Items.Clear();
            foreach (var i in lista)
            {
                var item = new ListViewItem(i.Predeterminada ? i.Nombre + "  ★" : i.Nombre) { Tag = i.Sistema };
                item.SubItems.Add(Textos.EstadoImpresora(i.Estado));
                item.SubItems.Add(i.Detalle);
                if (i.Estado == "ocupada" || i.Estado == "pausada") item.ForeColor = Ambar;
                else if (i.Estado == "error" || i.Estado == "sin_papel") item.ForeColor = Rojo;
                if (i.Sistema == elegida) item.Selected = true;
                _impresoras.Items.Add(item);
            }
            _impresoras.EndUpdate();
            AjustaColumnas();
        }

        void ActualizaBotones()
        {
            _conexion.Enabled = !_ocupado;
            _accion.Enabled = !_ocupado;
            _desinstalar.Enabled = !_ocupado;
            _probar.Enabled = !_ocupado && _impresoras.Items.Count > 0 && _actual?.Agente != null;
        }

        static Color ColorDe(Tono t)
        {
            switch (t)
            {
                case Tono.Bien: return Verde;
                case Tono.Aviso: return Ambar;
                case Tono.Mal: return Rojo;
                default: return SystemColors.GrayText;
            }
        }

        // ------------------------------------------------------------ acciones

        void ConexionClic()
        {
            if (_conectadaMostrada == true)
            {
                var r = MessageBox.Show(this,
                    "Esta computadora dejará de imprimir lo que mande el hub hasta que se vuelva a conectar con una llave.\n\n¿Desconectarla?",
                    "Desconectar", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
                if (r == DialogResult.Yes) Ejecuta("--desconectar", null, "Desconectando…", null);
                return;
            }

            var hub = _hub.Text.Trim();
            var llave = _llave.Text.Trim();
            if (hub.Length == 0)
            {
                Aviso("Falta la dirección del hub.");
                _hub.Focus();
                return;
            }
            if (!llave.StartsWith("cpk_"))
            {
                Aviso("La llave de API empieza por «cpk_». Se crea en el panel del hub, en «Instalar agente».");
                _llave.Focus();
                return;
            }
            Ejecuta("--instalar",
                new DatosConexion { Hub = hub, Llave = llave, Nombre = _nombre.Text.Trim() },
                "Conectando con el hub e instalando el servicio…",
                ArrancaBandeja);
        }

        void AccionClic()
        {
            switch (_accion.Tag as AccionArranque? ?? AccionArranque.Ninguna)
            {
                case AccionArranque.Instalar:
                    Ejecuta("--instalar", null, "Instalando el servicio…", ArrancaBandeja);
                    break;
                case AccionArranque.Actualizar:
                    Ejecuta("--instalar", null, "Actualizando…", ArrancaBandeja);
                    break;
                case AccionArranque.Iniciar:
                    Ejecuta("--iniciar", null, "Arrancando el servicio…", null);
                    break;
            }
        }

        void DesinstalarClic()
        {
            var r = MessageBox.Show(this,
                "Se quita el servicio, el programa y la conexión con el hub. Esta computadora dejará de imprimir lo que mande el hub.\n\n¿Desinstalar?",
                "Desinstalar", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (r != DialogResult.Yes) return;
            Ejecuta("--desinstalar", null, "Desinstalando…", () =>
            {
                // Corriendo desde Archivos de programa, la carpeta no se puede borrar
                // mientras esta ventana siga abierta.
                if (Rutas.EsLaMisma(Path.GetDirectoryName(Rutas.EsteEjecutable), Rutas.Programa)) Close();
            });
        }

        void ProbarClic()
        {
            if (!_probar.Enabled) return;
            var item = _impresoras.SelectedItems.Count > 0
                ? _impresoras.SelectedItems[0]
                : _impresoras.Items.Cast<ListViewItem>().FirstOrDefault(i => i.Text.EndsWith("★"))
                  ?? _impresoras.Items.Cast<ListViewItem>().FirstOrDefault();
            if (item == null) return;
            var impresora = (string)item.Tag;
            var puerto = _actual?.Config?.PuertoPanel ?? 7717;
            _probar.Enabled = false;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var (ok, mensaje) = Panel.Prueba(puerto, impresora);
                BeginInvoke((Action)(() =>
                {
                    ActualizaBotones();
                    MessageBox.Show(this, mensaje, "Página de prueba", MessageBoxButtons.OK,
                        ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                }));
            });
        }

        void Ejecuta(string orden, DatosConexion datos, string progreso, Action alTerminar)
        {
            _ocupado = true;
            _progreso = progreso;
            _arranque.Text = progreso;
            UseWaitCursor = true;
            ActualizaBotones();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var r = Elevar.Corre(orden, datos);
                BeginInvoke((Action)(() =>
                {
                    _ocupado = false;
                    UseWaitCursor = false;
                    // Si salió bien, la sección de conexión se vuelve a pintar entera.
                    // Si no, se deja como está: quien tecleó la llave puede corregirla.
                    if (r.Ok) _conectadaMostrada = null;
                    if (!r.Cancelado)
                    {
                        MessageBox.Show(this, r.Mensaje, "print-server", MessageBoxButtons.OK,
                            r.Ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                        if (r.Ok) alTerminar?.Invoke();
                    }
                    if (!IsDisposed)
                    {
                        ActualizaBotones();
                        Refresca();
                    }
                }));
            });
        }

        void Aviso(string texto) =>
            MessageBox.Show(this, texto, "print-server", MessageBoxButtons.OK, MessageBoxIcon.Information);

        /// <summary>
        /// El icono junto al reloj, en esta sesión. Lo arranca la ventana y no la
        /// instalación porque la instalación corre como administrador, y el icono
        /// no tiene por qué.
        /// </summary>
        static void ArrancaBandeja()
        {
            try
            {
                if (!File.Exists(Rutas.Ventana)) return;
                if (Mutex.TryOpenExisting(@"Local\print-server-bandeja", out var m))
                {
                    m.Dispose();
                    return;
                }
                Process.Start(new ProcessStartInfo(Rutas.Ventana, "--bandeja")
                {
                    UseShellExecute = false,
                    WorkingDirectory = Rutas.Programa,
                });
            }
            catch (Exception)
            {
                // Sin icono también imprime; vuelve en el próximo inicio de sesión.
            }
        }

        void IntentaCaptura(Situacion s)
        {
            if (_captura == null) return;
            if (s.Agente == null && DateTime.UtcNow - _inicioCaptura < TimeSpan.FromSeconds(15)) return;
            var archivo = _captura;
            _captura = null;
            var t = new System.Windows.Forms.Timer { Interval = 1000 };
            t.Tick += (o, e) =>
            {
                t.Stop();
                t.Dispose();
                try
                {
                    using (var bmp = new Bitmap(Width, Height))
                    {
                        DrawToBitmap(bmp, new Rectangle(Point.Empty, Size));
                        bmp.Save(archivo, ImageFormat.Png);
                    }
                }
                catch (Exception ex)
                {
                    File.WriteAllText(archivo + ".error.txt", ex.ToString());
                }
                Close();
            };
            t.Start();
        }

        // -------------------------------------------------------- Win32 menudo

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr ventana, int mensaje, IntPtr w, IntPtr l);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr ventana, int mensaje, IntPtr w, string l);

        /// <summary>
        /// El escudo de Windows en el botón: avisa de que pulsarlo pide permiso
        /// de administrador, como en el Panel de control.
        /// </summary>
        static void Escudo(Button b)
        {
            b.FlatStyle = FlatStyle.System;
            SendMessage(b.Handle, 0x160C /* BCM_SETSHIELD */, IntPtr.Zero, (IntPtr)1);
            b.AutoSize = false;
            AjustaBoton(b);
        }

        /// <summary>
        /// Un botón con escudo no calcula bien su ancho solo: el icono no cuenta.
        /// </summary>
        static void AjustaBoton(Button b)
        {
            if (b.AutoSize) return;
            var texto = TextRenderer.MeasureText(b.Text, b.Font);
            b.Size = new Size(texto.Width + b.LogicalToDeviceUnits(46), Math.Max(texto.Height + b.LogicalToDeviceUnits(14), b.LogicalToDeviceUnits(30)));
        }

        /// <summary>Texto gris dentro de una caja vacía (EM_SETCUEBANNER).</summary>
        static void Pista(TextBox caja, string texto) =>
            SendMessage(caja.Handle, 0x1501, (IntPtr)1, texto);
    }
}
