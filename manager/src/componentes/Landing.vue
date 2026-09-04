<script setup>
// La presentación. Explica el problema antes que el producto: quien llega aquí
// suele venir de pelearse con una impresora en otra red, no buscando un
// «servidor de impresión».
const ejemplo = `curl -X POST https://tu-hub/v1/trabajos \\
  -H "authorization: Bearer cpk_tu_llave" \\
  -H "content-type: application/json" \\
  -d '{
        "impresora_nombre": "Etiquetas recepción",
        "formato": "raw",
        "contenido_b64": "XlhBXkZPNTAsNTBeQTBOLDQwXkZESG9sYV5GU15YWg==",
        "idempotencia": "mov-8891"
      }'`

const diagrama = `   Tu aplicación                 Hub                        Agente
  ───────────────           ─────────────            ──────────────────
   POST /v1/trabajos  ───►   cola + estado   ◄────    WebSocket saliente
   (HTTP, una llave)         REST + panel             spooler del sistema
                                                      winspool · CUPS`
</script>

<template>
  <section class="hero">
    <div class="contenedor">
      <span class="etiqueta">Código abierto · Apache-2.0</span>
      <h1>Imprimir desde donde sea, en la impresora que sea</h1>
      <p class="lema">
        Una térmica colgada de una PC en el almacén, un ERP en otro país, un
        terminal en el pasillo. Mandas el trabajo por HTTP y sale por donde
        tiene que salir — sin abrir puertos, sin VPN y sin IP fija.
      </p>
      <div class="acciones">
        <a href="#/panel" class="boton">Crear una cuenta</a>
        <a href="#/docs" class="boton suave">Ver el API</a>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <div class="diagrama">{{ diagrama }}</div>
      <p class="apagado centro" style="margin-top: 16px">
        El agente marca hacia el hub. El firewall del cliente no se entera, y no
        hay nada que configurar en su router.
      </p>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Lo que suele doler</h2>
      <p class="apagado" style="max-width: 640px">
        Nada de esto es un problema de impresión: es un problema de red, de
        colas y de duplicados.
      </p>
      <div class="rejilla" style="margin-top: 28px">
        <div class="tarjeta">
          <h3>La impresora no es de red</h3>
          <p>
            Una USB enchufada a una computadora no la ve nadie más. Aquí queda
            disponible para cualquier aplicación con permiso.
          </p>
        </div>
        <div class="tarjeta">
          <h3>La red es del cliente</h3>
          <p>
            No vas a pedirle a un cliente que abra un puerto. El agente sale
            hacia afuera, como saldría un navegador.
          </p>
        </div>
        <div class="tarjeta">
          <h3>Se imprime dos veces</h3>
          <p>
            Un reintento en el peor momento saca 300 etiquetas repetidas. Cada
            trabajo lleva llave de idempotencia y el agente recuerda lo que ya
            imprimió.
          </p>
        </div>
        <div class="tarjeta">
          <h3>La computadora estaba apagada</h3>
          <p>
            El trabajo espera en cola y sale al volver. Y si esperó demasiado se
            descarta: nadie quiere la orden de ayer saliendo hoy.
          </p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Tres pasos</h2>
      <div class="pasos" style="margin-top: 28px">
        <div class="paso">
          <h3>Levanta el hub</h3>
          <p class="apagado">
            El nuestro o el tuyo. Solo necesita un Postgres; las migraciones se
            aplican solas.
          </p>
        </div>
        <div class="paso">
          <h3>Instala el agente</h3>
          <p class="apagado">
            En la computadora que tiene las impresoras. Doble clic, la dirección
            del hub y una llave de API. Queda como servicio.
          </p>
        </div>
        <div class="paso">
          <h3>Manda a imprimir</h3>
          <p class="apagado">
            Una llamada HTTP desde lo que ya tengas: Dart, PHP, FoxPro, un
            <code>curl</code> en un script.
          </p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Así se manda una etiqueta</h2>
      <pre>{{ ejemplo }}</pre>
      <p class="apagado">
        <code>raw</code> pasa los bytes tal cual — ZPL, EPL, ESC/POS, PCL — que
        es justo lo que no hay que dejar que nadie «mejore» por el camino.
        También acepta <code>pdf</code>, <code>imagen</code> y
        <code>texto</code>.
      </p>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Lo que trae</h2>
      <div class="rejilla" style="margin-top: 24px">
        <div class="tarjeta">
          <h3>Estado real de cada impresora</h3>
          <p>Lista, ocupada, sin papel, con error, o la computadora apagada. La diferencia importa: una se arregla con papel y la otra encendiendo.</p>
        </div>
        <div class="tarjeta">
          <h3>Panel en la propia máquina</h3>
          <p>Un icono junto al reloj abre el estado del agente y permite una impresión de prueba, sin abrir el panel de administración.</p>
        </div>
        <div class="tarjeta">
          <h3>Todo por API</h3>
          <p>Lo que hace el panel se hace por REST, con una llave de administración. Sin nada reservado a la interfaz.</p>
        </div>
        <div class="tarjeta">
          <h3>Multiorganización</h3>
          <p>Cada organización ve lo suyo. Sirve para una nave o para un proveedor que atiende a cuarenta clientes.</p>
        </div>
        <div class="tarjeta">
          <h3>Historia de cada trabajo</h3>
          <p>Cuándo se encoló, cuándo salió y qué contestó el agente. «No imprimió» deja de ser una discusión.</p>
        </div>
        <div class="tarjeta">
          <h3>Tuyo si quieres</h3>
          <p>Apache-2.0. Móntalo en tu servidor, cámbialo, ofrécelo a tus clientes. No hay pieza escondida.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor centro">
      <h2>Móntalo tú mismo</h2>
      <p class="apagado" style="max-width: 560px; margin: 0 auto 22px">
        Un contenedor y un Postgres. Sin licencias por impresora, sin cuota por
        equipo, sin llamar a nadie.
      </p>
      <pre style="text-align: left; max-width: 560px; margin: 0 auto 22px">docker compose up -d</pre>
      <a href="#/docs" class="boton">Leer la documentación</a>
    </div>
  </section>
</template>
