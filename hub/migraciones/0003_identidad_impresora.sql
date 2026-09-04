-- Cómo reconocer una impresora sin saberse el nombre de su cola.
--
-- El nombre que trae el sistema —«PC42t-203-ESim»— es el de una cola de CUPS o
-- de Windows, y no le dice nada a quien acaba de enchufar una etiquetadora y
-- mira la lista buscando la suya. El agente ya puede averiguar quién la
-- fabrica, cómo está conectada y su número de serie; aquí se guardan.
--
-- Ninguno de estos datos hace falta para imprimir. Hacen falta para reconocerla.

alter table print.impresora
  add column if not exists fabricante text not null default '',
  add column if not exists modelo     text not null default '',
  add column if not exists conexion   text not null default '',
  add column if not exists serie      text not null default '';
