<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '../api.js'

const trabajos = ref([])
const impresoras = ref([])
const detalle = ref(null)
const error = ref('')
const filtro = ref('')
let temporizador

// Prueba de impresión desde el panel: es la pregunta de todo el que acaba de
// instalar un agente.
const prueba = ref({ impresora: '', texto: 'Prueba de chalona-print' })
const mensaje = ref('')

const color = (e) =>
  e === 'hecho' ? 'ok' : ['fallido', 'cancelado'].includes(e) ? 'mal' : 'tibio'

async function carga() {
  try {
    const q = filtro.value ? `?estado=${filtro.value}` : ''
    trabajos.value = (await api.get(`/v1/trabajos${q}`)).trabajos
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function abre(t) {
  detalle.value = await api.get(`/v1/trabajos/${t.id}`)
}

async function cancela(t) {
  try {
    await api.post(`/v1/trabajos/${t.id}/cancelar`, {})
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function imprimePrueba() {
  mensaje.value = ''
  try {
    const t = await api.post('/v1/trabajos', {
      impresora: Number(prueba.value.impresora),
      texto: prueba.value.texto,
      nombre: 'Prueba desde el panel',
    })
    mensaje.value = `Trabajo ${t.id} enviado.`
    await carga()
  } catch (e) {
    mensaje.value = e.message
  }
}

const hora = (s) => (s ? new Date(s).toLocaleString() : '')

onMounted(async () => {
  await carga()
  impresoras.value = (await api.get('/v1/impresoras')).impresoras
  if (impresoras.value.length) prueba.value.impresora = impresoras.value[0].id
  temporizador = setInterval(carga, 4000)
})
onUnmounted(() => clearInterval(temporizador))
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Trabajos</h2>
    <select v-model="filtro" @change="carga" style="width: auto">
      <option value="">Todos</option>
      <option value="en_cola">En cola</option>
      <option value="enviado">Enviados</option>
      <option value="imprimiendo">Imprimiendo</option>
      <option value="hecho">Hechos</option>
      <option value="fallido">Fallidos</option>
    </select>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div class="tarjeta" style="margin-bottom: 20px" v-if="impresoras.length">
    <h3>Imprimir una prueba</h3>
    <div style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end">
      <div style="flex: 1; min-width: 200px">
        <label>Impresora</label>
        <select v-model="prueba.impresora">
          <option v-for="i in impresoras" :key="i.id" :value="i.id">{{ i.nombre }}</option>
        </select>
      </div>
      <div style="flex: 2; min-width: 220px">
        <label>Texto</label>
        <input v-model="prueba.texto" />
      </div>
      <button class="boton" @click="imprimePrueba">Imprimir</button>
    </div>
    <p v-if="mensaje" class="apagado" style="margin: 10px 0 0">{{ mensaje }}</p>
  </div>

  <table>
    <thead>
      <tr><th>#</th><th>Estado</th><th>Impresora</th><th>Formato</th><th>Creado</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="t in trabajos" :key="t.id">
        <td>{{ t.id }}</td>
        <td>
          <span class="estado">
            <span class="punto" :class="color(t.estado)"></span>{{ t.estado }}
          </span>
          <div v-if="t.detalle" class="apagado" style="font-size: 13px">{{ t.detalle }}</div>
        </td>
        <td>{{ t.impresora }}</td>
        <td class="apagado">{{ t.formato }} · {{ t.copias }}×</td>
        <td class="apagado" style="font-size: 13px">{{ hora(t.creado) }}</td>
        <td style="white-space: nowrap">
          <button class="boton suave chico" @click="abre(t)">Ver</button>
          <button
            v-if="['en_cola', 'enviado'].includes(t.estado)"
            class="boton suave chico"
            @click="cancela(t)"
            style="margin-left: 6px"
          >
            Cancelar
          </button>
        </td>
      </tr>
    </tbody>
  </table>
  <p v-if="!trabajos.length" class="apagado">Nada por aquí todavía.</p>

  <div v-if="detalle" class="tarjeta" style="margin-top: 20px">
    <div class="cabecera-seccion">
      <h3>Trabajo {{ detalle.id }}</h3>
      <button class="boton suave chico" @click="detalle = null">Cerrar</button>
    </div>
    <table>
      <tbody>
        <tr v-for="e in detalle.eventos" :key="e.creado + e.tipo">
          <td>{{ e.tipo }}</td>
          <td class="apagado">{{ e.detalle }}</td>
          <td class="apagado" style="font-size: 13px">{{ hora(e.creado) }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
