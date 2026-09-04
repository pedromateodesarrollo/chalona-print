-- Un formato nuevo: `prueba`.
--
-- La prueba de impresión no puede armarla ni el panel ni el hub: ninguno de
-- los dos sabe si la impresora de enfrente habla EPL, ZPL o texto. Mandar
-- texto plano a una etiquetadora en modo ESim es exactamente lo que no
-- imprime nada y deja el trabajo en «hecho», que es peor que fallar.
--
-- Con `prueba`, el contenido lo genera el agente, que sí conoce el modelo y
-- el driver de cada cola.

alter table print.trabajo drop constraint if exists trabajo_formato_check;
alter table print.trabajo
  add constraint trabajo_formato_check
  check (formato in ('raw', 'pdf', 'imagen', 'texto', 'prueba'));
