
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'policia';
ALTER TYPE public.tipo_movimiento ADD VALUE IF NOT EXISTS 'multa';
ALTER TYPE public.tipo_movimiento ADD VALUE IF NOT EXISTS 'pago_multa';
ALTER TYPE public.tipo_movimiento ADD VALUE IF NOT EXISTS 'sueldo';
ALTER TYPE public.tipo_movimiento ADD VALUE IF NOT EXISTS 'impuesto';
ALTER TYPE public.tipo_movimiento ADD VALUE IF NOT EXISTS 'compra_membresia';

DO $$ BEGIN
  CREATE TYPE public.estado_multa AS ENUM ('pendiente','pagada','cancelada');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

UPDATE public.usuarios SET membresia = 'basica' WHERE membresia IS NOT NULL;
UPDATE public.membresias SET tipo = 'basica' WHERE tipo IS NOT NULL;

ALTER TABLE public.usuarios ALTER COLUMN membresia DROP DEFAULT;
ALTER TABLE public.usuarios ALTER COLUMN membresia TYPE text USING membresia::text;
ALTER TABLE public.membresias ALTER COLUMN tipo TYPE text USING tipo::text;

DROP TYPE IF EXISTS public.tipo_membresia CASCADE;
CREATE TYPE public.tipo_membresia AS ENUM ('basica','gold','zafiro','esmeralda','diamond','ruby','ruby_plus');

ALTER TABLE public.usuarios
  ALTER COLUMN membresia TYPE public.tipo_membresia USING 'basica'::public.tipo_membresia,
  ALTER COLUMN membresia SET DEFAULT 'basica'::public.tipo_membresia;

ALTER TABLE public.membresias
  ALTER COLUMN tipo TYPE public.tipo_membresia USING 'basica'::public.tipo_membresia;

ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS impuestos_pendientes numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ultimo_impuesto_en timestamptz;
