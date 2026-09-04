<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api.js'

const llaves = ref([])
const error = ref('')
const creada = ref(null)
const nombre = ref('')
const permisos = ref(['trabajos:escribir', 'impresoras:leer', 'agentes:registrar'])
const dominio = ref('')
const dominios = ref([])
const confirmando = ref(null)

const todos = [
  ['trabajos:escribir', 'Mandar a imprimir'],
  ['trabajos:leer', 'Consultar trabajos'],
  ['impresoras:leer', 'Ver impresoras'],
  ['agentes:registrar', 'Instalar agentes'],
  ['admin', 'Administrar todo (usuarios, llaves, agentes)'],
]

async function carga() {
  try {
    llaves.value = (await api.get('/v1/llaves')).llaves
    dominios.value = (await api.get('/v1/dominios')).dominios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    creada.value = await api.post('/v1/llaves', {
      nombre: nombre.value,
      permisos: permisos.value,
      dominio: dominio.value || undefined,
    })
    nombre.value = ''
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function revoca(l) {
  if (confirmando.value !== l.id) {
    confirmando.value = l.id
    setTimeout(() => (confirmando.value === l.id ? (confirmando.value = null) : null), 4000)
    return
  }
  await api.del(`/v1/llaves/${l.id}`)
  confirmando.value = null
  await carga()
}

const hora = (s) => (s ? new Date(s).toLocaleString() : 'nunca')
onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Llaves de API</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="creada" class="exito">
    <strong>{{ creada.nombre }}</strong> — cópiala ahora: no se vuelve a enseñar.
    <div class="secreto">{{ creada.llave }}</div>
    <button class="boton suave chico" style="margin-top: 10px" @click="creada = null">Ya la copié</button>
  </div>

  <div class="tarjeta" style="margin-bottom: 20px">
    <h3>Crear una llave</h3>
    <p class="apagado">
      Una por aplicación: así se sabe cuál revocar cuando haga falta, sin dejar
      mudas a las demás.
    </p>
    <label>Nombre</label>
    <input v-model="nombre" placeholder="WMS del almacén" style="max-width: 380px" />
    <label>Dominio</label>
    <select v-model="dominio" style="max-width: 380px">
      <option value="">Toda la organización</option>
      <option v-for="d in dominios" :key="d.id" :value="d.id">{{ d.nombre }}</option>
    </select>
    <p class="apagado" style="font-size: 13px; margin: 6px 0 0">
      Acotada a un dominio, la llave solo instala agentes e imprime ahí.
    </p>

    <label>Permisos</label>
    <div v-for="[id, texto] in todos" :key="id" style="margin-bottom: 4px">
      <label style="display: flex; gap: 8px; align-items: center; font-weight: 400; margin: 0">
        <input type="checkbox" :value="id" v-model="permisos" style="width: auto" />
        <span>{{ texto }} <code class="apagado">{{ id }}</code></span>
      </label>
    </div>
    <button class="boton" style="margin-top: 14px" :disabled="!nombre" @click="crea">Crear</button>
  </div>

  <table v-if="llaves.length">
    <thead>
      <tr><th>Nombre</th><th>Prefijo</th><th>Dominio</th><th>Permisos</th><th>Último uso</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="l in llaves" :key="l.id" :style="l.revocada ? 'opacity:.45' : ''">
        <td>{{ l.nombre }}</td>
        <td><code>cpk_{{ l.prefijo }}_…</code></td>
        <td class="apagado">{{ l.dominio_nombre || 'toda la organización' }}</td>
        <td class="apagado" style="font-size: 13px">{{ (l.permisos || []).join(', ') }}</td>
        <td class="apagado" style="font-size: 13px">{{ hora(l.ultimo_uso) }}</td>
        <td>
          <span v-if="l.revocada" class="apagado">revocada</span>
          <button v-else class="boton chico" :class="confirmando === l.id ? 'peligro' : 'suave'" @click="revoca(l)">
            {{ confirmando === l.id ? '¿Seguro?' : 'Revocar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</template>
