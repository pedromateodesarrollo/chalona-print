<script setup>
import { ref, computed, onMounted } from 'vue'
import { api } from '../api.js'

const descargas = ref([])
const dominios = ref([])
const dominio = ref('')
const llave = ref('')
const creando = ref(false)
const error = ref('')
const sistema = ref('windows')
const hub = location.origin

const sistemas = [
  ['windows', 'Windows'],
  ['linux', 'Linux'],
  ['macos', 'macOS'],
]

const binario = computed(() => descargas.value.find((d) => d.sistema === sistema.value))
const clave = computed(() => llave.value || 'cpk_tu_llave')

// La llave se crea aquí mismo: el secreto solo se enseña al crearla, así que
// este es el único momento en que se puede dejar el comando listo para pegar.
async function creaLlave() {
  creando.value = true
  error.value = ''
  try {
    const d = await api.post('/v1/llaves', {
      nombre: `Instalación ${new Date().toLocaleDateString()}`,
      permisos: ['trabajos:escribir', 'impresoras:leer', 'agentes:registrar'],
      dominio: dominio.value || undefined,
    })
    llave.value = d.llave
  } catch (e) {
    error.value = e.message
  } finally {
    creando.value = false
  }
}

const mb = (b) => `${(b / 1024 / 1024).toFixed(1)} MB`

onMounted(async () => {
  try {
    descargas.value = (await api.get('/v1/descargas')).descargas
    dominios.value = (await api.get('/v1/dominios')).dominios
  } catch (e) {
    error.value = e.message
  }
})
</script>

<template>
  <div class="cabecera-seccion"><h2>Instalar un agente</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <p class="apagado" style="max-width: 640px">
    El agente va en la computadora que tiene las impresoras. Solo necesita dos
    datos: la dirección de este hub y una llave de API.
  </p>

  <div class="tarjeta" style="margin: 18px 0">
    <h3>1. La llave</h3>
    <div style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end">
      <div style="flex: 1; min-width: 200px">
        <label>Dominio de la computadora</label>
        <select v-model="dominio">
          <option value="">Toda la organización</option>
          <option v-for="d in dominios" :key="d.id" :value="d.id">{{ d.nombre }}</option>
        </select>
      </div>
      <button class="boton" :disabled="creando" @click="creaLlave">
        {{ creando ? 'Creando…' : 'Crear llave para esta instalación' }}
      </button>
    </div>
    <div v-if="llave" class="exito" style="margin-top: 14px">
      Llave creada. Ya va metida en el comando de abajo — no se vuelve a enseñar.
      <div class="secreto">{{ llave }}</div>
    </div>
    <p v-else class="apagado" style="font-size: 13px; margin: 10px 0 0">
      Si ya tienes una guardada, pégala en el comando en lugar de
      <code>cpk_tu_llave</code>.
    </p>
  </div>

  <div class="tarjeta">
    <h3>2. El programa</h3>
    <div style="display: flex; gap: 8px; margin: 12px 0 16px; flex-wrap: wrap">
      <button
        v-for="[id, texto] in sistemas"
        :key="id"
        class="boton chico"
        :class="sistema === id ? '' : 'suave'"
        @click="sistema = id"
      >
        {{ texto }}
      </button>
    </div>

    <!-- Windows -->
    <template v-if="sistema === 'windows'">
      <template v-if="binario">
        <p>
          Baja el programa y haz doble clic. Te pregunta los dos datos en el
          navegador, se instala como servicio y deja un icono junto al reloj.
        </p>
        <p>
          <a class="boton" :href="binario.url">Descargar para Windows ({{ mb(binario.bytes) }})</a>
        </p>
        <p class="apagado" style="font-size: 13px">
          O en PowerShell como administrador, sin tocar nada más:
        </p>
        <pre>&amp; ([scriptblock]::Create((irm {{ hub }}/descargas/instalar.ps1))) `
    -Hub {{ hub }} -Llave {{ clave }}</pre>
      </template>
      <template v-else>
        <p class="aviso">
          El ejecutable de Windows todavía no está publicado en este hub.
        </p>
        <p class="apagado">
          Se compila en Windows —Dart genera para el sistema donde corre, no
          cruza—, así que sale del flujo de compilación del repositorio o de una
          máquina Windows con el SDK:
        </p>
        <pre>cd agente
dart compile exe bin/chalona_print_agente.dart -o chalona-print-agente-windows-x64.exe</pre>
        <p class="apagado" style="font-size: 13px">
          El archivo se deja en la carpeta de descargas del hub
          (<code>PRINT_DESCARGAS</code>) y aparece aquí solo.
        </p>
      </template>
    </template>

    <!-- Linux y macOS -->
    <template v-else>
      <p>Una línea, y queda instalado y arrancando con la máquina:</p>
      <pre>curl -fsSL {{ hub }}/descargas/instalar.sh | sudo bash -s -- \
  --hub {{ hub }} --llave {{ clave }}</pre>
      <template v-if="binario">
        <p class="apagado" style="font-size: 13px">
          O a mano:
          <a :href="binario.url">{{ binario.archivo }}</a> ({{ mb(binario.bytes) }})
        </p>
        <pre>chmod +x {{ binario.archivo }}
sudo ./{{ binario.archivo }} configurar --hub {{ hub }} --llave {{ clave }}
sudo ./{{ binario.archivo }} instalar</pre>
      </template>
      <p v-else class="aviso">
        El ejecutable para {{ sistema === 'linux' ? 'Linux' : 'macOS' }} todavía
        no está publicado en este hub.
      </p>
    </template>
  </div>

  <div class="tarjeta" style="margin-top: 16px">
    <h3>3. Comprobar</h3>
    <p class="apagado">
      La computadora aparece sola en <strong>Agentes</strong> y sus impresoras en
      <strong>Impresoras</strong>. En la propia máquina, el panel del agente vive
      en <code>http://127.0.0.1:7717</code> y desde ahí se manda una impresión de
      prueba.
    </p>
  </div>

  <div v-if="descargas.length" class="tarjeta" style="margin-top: 16px">
    <h3>Lo publicado en este hub</h3>
    <table>
      <thead><tr><th>Archivo</th><th>Sistema</th><th>Tamaño</th><th>sha256</th></tr></thead>
      <tbody>
        <tr v-for="d in descargas" :key="d.archivo">
          <td><a :href="d.url">{{ d.archivo }}</a></td>
          <td class="apagado">{{ d.sistema }}</td>
          <td class="apagado">{{ mb(d.bytes) }}</td>
          <td class="apagado" style="font-size: 12px">
            <code>{{ d.sha256.slice(0, 16) }}…</code>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
