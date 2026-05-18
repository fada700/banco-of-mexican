
-- ============ ENUMS ============
DO $$ BEGIN
  CREATE TYPE public.estado_cuenta_general AS ENUM ('activa','congelada','cerrada');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.estado_tarjeta_debito AS ENUM ('activa','congelada','cerrada');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- estado_credito ya existe; añadimos 'cerrada' si falta
DO $$ BEGIN
  ALTER TYPE public.estado_credito ADD VALUE IF NOT EXISTS 'cerrada';
EXCEPTION WHEN others THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.estado_notificacion AS ENUM ('enviado','fallido');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============ COLUMNAS NUEVAS ============
ALTER TABLE public.usuarios
  ADD COLUMN IF NOT EXISTS estado_cuenta public.estado_cuenta_general NOT NULL DEFAULT 'activa',
  ADD COLUMN IF NOT EXISTS clabe text;

CREATE UNIQUE INDEX IF NOT EXISTS usuarios_clabe_unique ON public.usuarios(clabe) WHERE clabe IS NOT NULL;

ALTER TABLE public.tarjetas_debito
  ADD COLUMN IF NOT EXISTS estado public.estado_tarjeta_debito NOT NULL DEFAULT 'activa';

ALTER TABLE public.tarjetas_credito
  ADD COLUMN IF NOT EXISTS fecha_corte timestamptz;

-- Check constraints saldos no negativos
DO $$ BEGIN
  ALTER TABLE public.usuarios ADD CONSTRAINT usuarios_saldo_banco_nonneg CHECK (saldo_banco >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN check_violation THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.usuarios ADD CONSTRAINT usuarios_saldo_cartera_nonneg CHECK (saldo_cartera >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN check_violation THEN NULL; END $$;

-- ============ GENERAR CLABE ============
CREATE OR REPLACE FUNCTION public.generar_clabe()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c text;
BEGIN
  LOOP
    c := '6461801' || lpad((floor(random()*99999999999)::bigint)::text, 11, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.usuarios WHERE clabe = c);
  END LOOP;
  RETURN c;
END $$;

UPDATE public.usuarios SET clabe = public.generar_clabe() WHERE clabe IS NULL;

CREATE OR REPLACE FUNCTION public.usuarios_set_clabe()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.clabe IS NULL THEN NEW.clabe := public.generar_clabe(); END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_usuarios_clabe ON public.usuarios;
CREATE TRIGGER trg_usuarios_clabe BEFORE INSERT ON public.usuarios
FOR EACH ROW EXECUTE FUNCTION public.usuarios_set_clabe();

-- ============ AUDIT LOGS ============
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  realizado_por_id uuid,
  realizado_por_nombre text,
  realizado_por_rol text,
  accion text NOT NULL,
  entidad text,
  entidad_id uuid,
  cliente_nombre text,
  detalle jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip_address text,
  fecha_hora timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_logs_realizado_por_idx ON public.audit_logs(realizado_por_id);
CREATE INDEX IF NOT EXISTS audit_logs_fecha_idx ON public.audit_logs(fecha_hora DESC);
CREATE INDEX IF NOT EXISTS audit_logs_entidad_id_idx ON public.audit_logs(entidad_id);

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin ve audit" ON public.audit_logs;
CREATE POLICY "Admin ve audit" ON public.audit_logs FOR SELECT USING (public.has_role('admin'));

-- Sin policies de INSERT/UPDATE/DELETE: solo SECURITY DEFINER puede escribir

-- ============ NOTIFICATION LOG ============
CREATE TABLE IF NOT EXISTS public.notification_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL,
  discord_user_id text,
  tipo_notificacion text NOT NULL,
  mensaje text NOT NULL,
  estado public.estado_notificacion NOT NULL DEFAULT 'enviado',
  error text,
  enviado_en timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notif_usuario_idx ON public.notification_log(usuario_id);
CREATE INDEX IF NOT EXISTS notif_fecha_idx ON public.notification_log(enviado_en DESC);

ALTER TABLE public.notification_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Ver notifs propias o admin" ON public.notification_log;
CREATE POLICY "Ver notifs propias o admin" ON public.notification_log FOR SELECT
USING (usuario_id = public.current_usuario_id() OR public.has_role('admin'));

-- ============ ÍNDICES MOVIMIENTOS ============
CREATE INDEX IF NOT EXISTS movimientos_usuario_idx ON public.movimientos(usuario_id);
CREATE INDEX IF NOT EXISTS movimientos_fecha_idx ON public.movimientos(fecha DESC);

-- ============ HELPER: log_audit ============
CREATE OR REPLACE FUNCTION public.log_audit(
  _accion text,
  _entidad text,
  _entidad_id uuid,
  _cliente_nombre text,
  _detalle jsonb
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE staff_id uuid; staff_nombre text; staff_rol text;
BEGIN
  staff_id := public.current_usuario_id();
  IF staff_id IS NOT NULL THEN
    SELECT nombre INTO staff_nombre FROM usuarios WHERE id = staff_id;
    SELECT string_agg(role::text, ',') INTO staff_rol FROM roles_usuario WHERE usuario_id = staff_id;
  END IF;
  INSERT INTO audit_logs(realizado_por_id, realizado_por_nombre, realizado_por_rol, accion, entidad, entidad_id, cliente_nombre, detalle)
  VALUES (staff_id, staff_nombre, staff_rol, _accion, _entidad, _entidad_id, _cliente_nombre, COALESCE(_detalle, '{}'::jsonb));
END $$;

-- ============ BLOQUEAR OPS SI CUENTA NO ACTIVA ============
CREATE OR REPLACE FUNCTION public.op_depositar(_monto numeric)
 RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid uuid := public.current_usuario_id(); cartera numeric; est public.estado_cuenta_general;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT saldo_cartera, estado_cuenta INTO cartera, est FROM usuarios WHERE id = uid FOR UPDATE;
  IF est <> 'activa' THEN RAISE EXCEPTION 'Cuenta no activa (%)', est; END IF;
  IF cartera < _monto THEN RAISE EXCEPTION 'Saldo insuficiente en cartera'; END IF;
  UPDATE usuarios SET saldo_cartera = saldo_cartera - _monto, saldo_banco = saldo_banco + _monto WHERE id = uid;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'deposito', _monto, 'Depósito a cuenta');
END;
$function$;

CREATE OR REPLACE FUNCTION public.op_retirar(_monto numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid uuid := public.current_usuario_id(); banco numeric; est public.estado_cuenta_general;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT saldo_banco, estado_cuenta INTO banco, est FROM usuarios WHERE id = uid FOR UPDATE;
  IF est <> 'activa' THEN RAISE EXCEPTION 'Cuenta no activa (%)', est; END IF;
  IF banco < _monto THEN RAISE EXCEPTION 'Saldo insuficiente en banco'; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - _monto, saldo_cartera = saldo_cartera + _monto WHERE id = uid;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'retiro', _monto, 'Retiro a cartera');
END;
$function$;

CREATE OR REPLACE FUNCTION public.op_transferir(_destino_numero text, _monto numeric, _concepto text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid uuid := public.current_usuario_id(); destino usuarios%ROWTYPE; origen usuarios%ROWTYPE; pct numeric; comision numeric; total numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  IF _destino_numero IS NULL OR length(_destino_numero) = 0 THEN RAISE EXCEPTION 'Destino requerido'; END IF;
  SELECT * INTO destino FROM usuarios WHERE numero_cliente = _destino_numero OR clabe = _destino_numero;
  IF destino.id IS NULL THEN RAISE EXCEPTION 'Cliente destino no existe'; END IF;
  IF destino.id = uid THEN RAISE EXCEPTION 'No puedes transferirte a ti mismo'; END IF;
  IF destino.estado_cuenta <> 'activa' THEN RAISE EXCEPTION 'Cuenta destino no activa'; END IF;
  SELECT comision_porcentaje INTO pct FROM config WHERE id = 1;
  pct := COALESCE(pct, 0);
  comision := round((_monto * pct / 100)::numeric, 2);
  total := _monto + comision;
  SELECT * INTO origen FROM usuarios WHERE id = uid FOR UPDATE;
  IF origen.estado_cuenta <> 'activa' THEN RAISE EXCEPTION 'Tu cuenta no está activa'; END IF;
  IF origen.saldo_banco < total THEN RAISE EXCEPTION 'Saldo insuficiente. Necesitas %', total; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - total WHERE id = uid;
  UPDATE usuarios SET saldo_banco = saldo_banco + _monto WHERE id = destino.id;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion, contraparte_id)
    VALUES (uid, 'transferencia_enviada', _monto,
            'A ' || destino.nombre || ' (' || destino.numero_cliente || ')' ||
            CASE WHEN _concepto IS NOT NULL AND length(_concepto)>0 THEN ' — '||_concepto ELSE '' END, destino.id);
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion, contraparte_id)
    VALUES (destino.id, 'transferencia_recibida', _monto,
            'De ' || origen.nombre || ' (' || origen.numero_cliente || ')' ||
            CASE WHEN _concepto IS NOT NULL AND length(_concepto)>0 THEN ' — '||_concepto ELSE '' END, uid);
  IF comision > 0 THEN
    INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'comision', comision, 'Comisión por transferencia');
    PERFORM public.registrar_ganancia('comision_transferencia', uid, comision);
  END IF;
  RETURN jsonb_build_object('monto', _monto, 'comision', comision, 'total', total,
    'destino_nombre', destino.nombre, 'destino_numero', destino.numero_cliente, 'destino_id', destino.id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.usar_credito(_monto numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid uuid := public.current_usuario_id(); tc tarjetas_credito%ROWTYPE; disponible numeric; est public.estado_cuenta_general;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT estado_cuenta INTO est FROM usuarios WHERE id = uid;
  IF est <> 'activa' THEN RAISE EXCEPTION 'Cuenta no activa'; END IF;
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = uid FOR UPDATE;
  IF tc.id IS NULL OR tc.estado <> 'activa' THEN RAISE EXCEPTION 'No tienes tarjeta de crédito activa'; END IF;
  disponible := tc.limite - tc.saldo_usado;
  IF _monto > disponible THEN RAISE EXCEPTION 'Excede tu límite disponible (%)', disponible; END IF;
  UPDATE tarjetas_credito SET saldo_usado = saldo_usado + _monto,
    fecha_uso = COALESCE(fecha_uso, now()),
    fecha_corte = COALESCE(fecha_corte, now()),
    fecha_limite_pago = COALESCE(fecha_limite_pago, now() + interval '6 days') WHERE id = tc.id;
  UPDATE usuarios SET saldo_banco = saldo_banco + _monto WHERE id = uid;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (uid, 'uso_credito', _monto, 'Uso de crédito');
END;
$function$;

-- ============ STAFF: congelar / descongelar / cerrar / abrir ============
CREATE OR REPLACE FUNCTION public.congelar_cuenta(_usuario_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF u.estado_cuenta = 'cerrada' THEN RAISE EXCEPTION 'Cuenta cerrada, no se puede congelar'; END IF;
  UPDATE usuarios SET estado_cuenta = 'congelada' WHERE id = u.id;
  UPDATE tarjetas_debito SET estado = 'congelada', congelada = true WHERE usuario_id = u.id;
  PERFORM public.log_audit('CONGELAR_CUENTA','usuario', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'antes', u.estado_cuenta, 'despues', 'congelada'));
END $$;

CREATE OR REPLACE FUNCTION public.descongelar_cuenta(_usuario_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF u.estado_cuenta <> 'congelada' THEN RAISE EXCEPTION 'Cuenta no está congelada'; END IF;
  UPDATE usuarios SET estado_cuenta = 'activa' WHERE id = u.id;
  UPDATE tarjetas_debito SET estado = 'activa', congelada = false WHERE usuario_id = u.id;
  PERFORM public.log_audit('DESCONGELAR_CUENTA','usuario', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'antes','congelada','despues','activa'));
END $$;

CREATE OR REPLACE FUNCTION public.cerrar_cuenta(_usuario_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  UPDATE usuarios SET estado_cuenta = 'cerrada' WHERE id = u.id;
  UPDATE tarjetas_debito SET estado = 'cerrada', congelada = true WHERE usuario_id = u.id;
  UPDATE tarjetas_credito SET estado = 'cerrada' WHERE usuario_id = u.id;
  PERFORM public.log_audit('CERRAR_CUENTA','usuario', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'antes', u.estado_cuenta));
END $$;

CREATE OR REPLACE FUNCTION public.abrir_debito_manual(_usuario_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE; num text; ncvv text; venc text;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF EXISTS(SELECT 1 FROM tarjetas_debito WHERE usuario_id = u.id AND estado <> 'cerrada') THEN
    RAISE EXCEPTION 'Ya tiene tarjeta débito';
  END IF;
  num  := '4' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  ncvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  INSERT INTO tarjetas_debito(usuario_id, numero, cvv, vencimiento, estado) VALUES (u.id, num, ncvv, venc, 'activa');
  PERFORM public.log_audit('ABRIR_DEBITO','tarjeta_debito', u.id, u.nombre, jsonb_build_object('motivo', _motivo));
END $$;

CREATE OR REPLACE FUNCTION public.abrir_credito_manual(_usuario_id uuid, _limite numeric, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE; tc tarjetas_credito%ROWTYPE; num text; ncvv text; venc text;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  IF _limite IS NULL OR _limite <= 0 OR _limite > 10000000 THEN RAISE EXCEPTION 'Límite inválido'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  num  := '5' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  ncvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = u.id FOR UPDATE;
  IF tc.id IS NULL THEN
    INSERT INTO tarjetas_credito(usuario_id, estado, numero, cvv, vencimiento, limite)
    VALUES (u.id, 'activa', num, ncvv, venc, _limite);
  ELSE
    UPDATE tarjetas_credito SET estado='activa', numero=num, cvv=ncvv, vencimiento=venc, limite=_limite WHERE id = tc.id;
  END IF;
  PERFORM public.log_audit('ABRIR_CREDITO','tarjeta_credito', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'limite', _limite));
END $$;

-- ============ AUDIT en funciones existentes ============
CREATE OR REPLACE FUNCTION public.admin_ajustar_saldo(_usuario_id uuid, _delta numeric, _cuenta text, _motivo text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE u usuarios%ROWTYPE;
BEGIN
  IF NOT public.has_role('admin') THEN RAISE EXCEPTION 'Solo admin'; END IF;
  IF _delta = 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  IF _cuenta NOT IN ('banco','cartera') THEN RAISE EXCEPTION 'Cuenta inválida'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF _cuenta = 'banco' THEN
    IF u.saldo_banco + _delta < 0 THEN RAISE EXCEPTION 'Saldo banco quedaría negativo'; END IF;
    UPDATE usuarios SET saldo_banco = saldo_banco + _delta WHERE id = u.id;
  ELSE
    IF u.saldo_cartera + _delta < 0 THEN RAISE EXCEPTION 'Saldo cartera quedaría negativo'; END IF;
    UPDATE usuarios SET saldo_cartera = saldo_cartera + _delta WHERE id = u.id;
  END IF;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion)
    VALUES (u.id, CASE WHEN _delta > 0 THEN 'admin_dar' ELSE 'admin_quitar' END, abs(_delta),
            'Admin (' || _cuenta || ')' || CASE WHEN _motivo IS NOT NULL AND length(_motivo)>0 THEN ' — '||_motivo ELSE '' END);
  PERFORM public.log_audit(CASE WHEN _delta > 0 THEN 'ADD_BALANCE' ELSE 'REMOVE_BALANCE' END,
    'usuario', u.id, u.nombre,
    jsonb_build_object('cuenta', _cuenta, 'delta', _delta, 'motivo', _motivo));
END;
$function$;

CREATE OR REPLACE FUNCTION public.aprobar_tarjeta_credito(_solicitud_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE staff uuid := public.current_usuario_id(); s solicitudes%ROWTYPE; tc tarjetas_credito%ROWTYPE; num text; ncvv text; venc text; u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO s FROM solicitudes WHERE id = _solicitud_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF s.tipo <> 'tarjeta_credito' THEN RAISE EXCEPTION 'Tipo inválido'; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'Ya resuelta (%)', s.estado; END IF;
  num  := '5' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  ncvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = s.usuario_id FOR UPDATE;
  IF tc.id IS NULL THEN
    INSERT INTO tarjetas_credito(usuario_id, estado, numero, cvv, vencimiento, limite)
    VALUES (s.usuario_id, 'activa', num, ncvv, venc, 5000);
  ELSE
    UPDATE tarjetas_credito SET estado='activa', numero=num, cvv=ncvv, vencimiento=venc,
      limite = COALESCE(NULLIF(limite,0), 5000) WHERE id = tc.id;
  END IF;
  UPDATE solicitudes SET estado='aprobada', resuelta_por=staff, resuelta_en=now() WHERE id=s.id;
  SELECT * INTO u FROM usuarios WHERE id = s.usuario_id;
  PERFORM public.log_audit('APROBAR_CREDITO','solicitud', s.id, u.nombre, jsonb_build_object('solicitud', s.id));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rechazar_tarjeta_credito(_solicitud_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE staff uuid := public.current_usuario_id(); s solicitudes%ROWTYPE; u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO s FROM solicitudes WHERE id = _solicitud_id FOR UPDATE;
  IF s.id IS NULL OR s.tipo <> 'tarjeta_credito' THEN RAISE EXCEPTION 'Solicitud inválida'; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'Ya resuelta'; END IF;
  UPDATE tarjetas_credito SET estado='rechazada' WHERE usuario_id = s.usuario_id;
  UPDATE solicitudes SET estado='rechazada', resuelta_por=staff, resuelta_en=now() WHERE id=s.id;
  SELECT * INTO u FROM usuarios WHERE id = s.usuario_id;
  PERFORM public.log_audit('RECHAZAR_CREDITO','solicitud', s.id, u.nombre, jsonb_build_object('solicitud', s.id));
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajustar_limite_credito(_usuario_id uuid, _nuevo_limite numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE u usuarios%ROWTYPE; antes numeric;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  IF _nuevo_limite < 0 OR _nuevo_limite > 10000000 THEN RAISE EXCEPTION 'Límite inválido'; END IF;
  SELECT limite INTO antes FROM tarjetas_credito WHERE usuario_id = _usuario_id;
  UPDATE tarjetas_credito SET limite = _nuevo_limite WHERE usuario_id = _usuario_id;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  PERFORM public.log_audit('AJUSTAR_LIMITE','tarjeta_credito', _usuario_id, u.nombre,
    jsonb_build_object('antes', antes, 'despues', _nuevo_limite));
END;
$function$;

CREATE OR REPLACE FUNCTION public.condonar_deuda(_usuario_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE deuda numeric; u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT saldo_usado INTO deuda FROM tarjetas_credito WHERE usuario_id = _usuario_id FOR UPDATE;
  IF deuda IS NULL OR deuda <= 0 THEN RAISE EXCEPTION 'Sin deuda'; END IF;
  UPDATE tarjetas_credito SET saldo_usado = 0, fecha_uso = NULL, fecha_limite_pago = NULL, dias_vencidos = 0,
    estado = CASE WHEN estado='bloqueada' THEN 'activa' ELSE estado END WHERE usuario_id = _usuario_id;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (_usuario_id, 'condonacion', deuda, 'Deuda condonada');
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  PERFORM public.log_audit('CONDONAR_DEUDA','tarjeta_credito', _usuario_id, u.nombre, jsonb_build_object('monto', deuda));
END;
$function$;
