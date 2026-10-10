-- 0007 — Cómo se le habla a cada impresora: su protocolo
--
-- `driver` es el ESTÁNDAR: PDF por el driver de la impresora, lo mismo que la
-- página de prueba de Windows. Sirve con cualquier impresora que tenga driver
-- (una DYMO no entiende ZPL, ni EPL, ni texto). `zpl`, `epl` y `dp` son el
-- lenguaje crudo de una etiquetadora; `texto`, texto plano.
--
-- Se fija UNA VEZ por modelo —la primera vez que se ve uno nuevo— y vale para
-- todas las de ese modelo de la organización; una cola concreta puede salirse
-- del de su modelo (dos Honeywell con el mismo driver, una en ESim y otra en
-- Direct Protocol). Sin ninguno de los dos manda lo que deduce el agente, que
-- llega con el inventario en `protocolo_auto`.

create table print.modelo_protocolo (
  org         bigint not null references print.org(id) on delete cascade,
  modelo      text   not null check (modelo <> ''),
  protocolo   text   not null check (protocolo in ('driver', 'zpl', 'epl', 'dp', 'texto')),
  actualizado timestamptz not null default now(),
  primary key (org, modelo)
);

alter table print.impresora
  add column protocolo text check (protocolo in ('driver', 'zpl', 'epl', 'dp', 'texto')),
  add column protocolo_auto text not null default '';

-- El que manda: el de la cola, si no el de su modelo. Null = el del agente.
create function print.protocolo(i print.impresora) returns text
  language sql stable as $$
  select coalesce(
    i.protocolo,
    (select mp.protocolo from print.modelo_protocolo mp
      where mp.org = i.org and mp.modelo = i.modelo and i.modelo <> ''))
$$;
