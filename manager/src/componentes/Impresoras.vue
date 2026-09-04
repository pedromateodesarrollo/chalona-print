<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '../api.js'

const impresoras = ref([])
const error = ref('')
const editando = ref(null)
const nombreNuevo = ref('')
let temporizador

const textos = {
  lista: 'Lista',
  ocupada: 'Imprimiendo',
  pausada: 'En pausa',
  sin_papel: 'Sin papel',
  error: 'Con error',
  ausente: 'Ya no está en el sistema',
  sin_agente: 'Computadora apagada',
  desconocida: 'Desconocida',
}
const color = (e) =>
  e === 'lista' ? 'ok' : ['error', 'sin_papel', 'ausente', 'sin_agente'].includes(e) ? 'mal' : 'tibio'

async function carga() {
  try {
    impresoras.value = (await api.get('/v1/impresoras')).impresoras
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function renombra(i) {
  await api.patch(`/v1/impresoras/${i.id}`, { nombre: nombreNuevo.value })
  editando.value = null
  await carga()
}

// Se refresca solo: el estado de una impresora cambia cuando alguien echa papel
// al otro lado, no cuando aquí se pulsa un botón.
onMounted(() => {
  carga()
  temporizador = setInterval(carga, 5000)
})
onUnmounted(() => clearInterval(temporizador))
</script>

<template>
  <div class="cabecera-seccion"><h2>Impresoras</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <p v-if="!impresoras.length" class="apagado">
    Todavía no hay ninguna. Instala el agente en la computadora que las tiene y
    aparecerán solas.
  </p>

  <table v-else>
    <thead>
      <tr><th>Impresora</th><th>Estado</th><th>Computadora</th><th>Dominio</th><th>Cola</th><th>Formatos</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="i in impresoras" :key="i.id">
        <td>
          <template v-if="editando === i.id">
            <input v-model="nombreNuevo" @keyup.enter="renombra(i)" style="max-width: 220px" />
          </template>
          <template v-else>
            <strong>{{ i.nombre }}</strong>
            <div class="apagado" style="font-size: 13px"><code>{{ i.sistema }}</code></div>
          </template>
        </td>
        <td>
          <span class="estado">
            <span class="punto" :class="color(i.estado)"></span>
            {{ textos[i.estado] || i.estado }}
          </span>
          <div v-if="i.detalle" class="apagado" style="font-size: 13px">{{ i.detalle }}</div>
        </td>
        <td>
          {{ i.agente_nombre }}
          <!-- «agente» explícito: en una fila de impresora, un «conectada» a
               secas se lee como si hablara de la impresora, y es del agente. -->
          <div class="apagado" style="font-size: 13px">
            {{ i.agente_conectado ? 'agente conectado' : 'agente sin conexión' }}
          </div>
        </td>
        <td class="apagado">{{ i.dominio_nombre || '—' }}</td>
        <td>{{ i.cola }}</td>
        <td class="apagado" style="font-size: 13px">{{ (i.formatos || []).join(', ') }}</td>
        <td>
          <button
            class="boton suave chico"
            @click="editando === i.id ? renombra(i) : ((editando = i.id), (nombreNuevo = i.nombre))"
          >
            {{ editando === i.id ? 'Guardar' : 'Renombrar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</template>
