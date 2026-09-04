<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api.js'

const dominios = ref([])
const error = ref('')
const nuevo = ref({ nombre: '', descripcion: '' })
const confirmando = ref(null)

async function carga() {
  try {
    dominios.value = (await api.get('/v1/dominios')).dominios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    await api.post('/v1/dominios', nuevo.value)
    nuevo.value = { nombre: '', descripcion: '' }
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function borra(d) {
  if (confirmando.value !== d.id) {
    confirmando.value = d.id
    setTimeout(() => (confirmando.value === d.id ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/dominios/${d.id}`)
    confirmando.value = null
    await carga()
  } catch (e) {
    error.value = e.message
    confirmando.value = null
  }
}

onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Dominios</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <p class="apagado" style="max-width: 620px">
    Un dominio es dónde ocurren las cosas: una sucursal, un almacén, un cliente.
    Agrupa las computadoras con agente y sus impresoras, y una llave de API
    entregada a un dominio solo puede instalar e imprimir ahí.
  </p>

  <div class="tarjeta" style="margin: 18px 0">
    <h3>Crear un dominio</h3>
    <div style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end">
      <div style="flex: 1; min-width: 200px">
        <label>Nombre</label>
        <input v-model="nuevo.nombre" placeholder="Sucursal Santiago" />
      </div>
      <div style="flex: 2; min-width: 220px">
        <label>Descripción</label>
        <input v-model="nuevo.descripcion" placeholder="Opcional" />
      </div>
      <button class="boton" :disabled="!nuevo.nombre" @click="crea">Crear</button>
    </div>
  </div>

  <table>
    <thead>
      <tr><th>Dominio</th><th>Agentes</th><th>Impresoras</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="d in dominios" :key="d.id">
        <td>
          <strong>{{ d.nombre }}</strong>
          <div class="apagado" style="font-size: 13px">
            <code>{{ d.slug }}</code>
            <span v-if="d.descripcion"> · {{ d.descripcion }}</span>
          </div>
        </td>
        <td>{{ d.agentes }}</td>
        <td>{{ d.impresoras }}</td>
        <td>
          <button class="boton chico" :class="confirmando === d.id ? 'peligro' : 'suave'" @click="borra(d)">
            {{ confirmando === d.id ? '¿Seguro?' : 'Quitar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</template>
