
CREATE TABLE IF NOT EXISTS public.config_membresias (
  tipo public.tipo_membresia PRIMARY KEY,
  costo numeric NOT NULL DEFAULT 0,
  tx_diarias int NOT NULL DEFAULT 5,
  tx_grandes_diarias int NOT NULL DEFAULT 2,
  monto_grande numeric NOT NULL DEFAULT 55000,
  debito_max numeric NOT NULL DEFAULT 100000,
  cartera_max numeric NOT NULL DEFAULT 65000,
  credito_max numeric NOT NULL DEFAULT 0,
  seguridad_antihackeo_pct int NOT NULL DEFAULT 0,
  seguro_dinero_pct int NOT NULL DEFAULT 0,
  nivel_soporte text NOT NULL DEFAULT 'normal',
  role_id_discord text,
  impuesto_pct numeric NOT NULL DEFAULT 20,
  orden int NOT NULL DEFAULT 0
);
ALTER TABLE public.config_membresias ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "lectura config_membresias" ON public.config_membresias;
CREATE POLICY "lectura config_membresias" ON public.config_membresias FOR SELECT USING (true);
DROP POLICY IF EXISTS "admin edita config_membresias" ON public.config_membresias;
CREATE POLICY "admin edita config_membresias" ON public.config_membresias FOR ALL
  USING (public.has_role('admin')) WITH CHECK (public.has_role('admin'));

INSERT INTO public.config_membresias (tipo, costo, tx_diarias, tx_grandes_diarias, monto_grande, debito_max, cartera_max, credito_max, seguridad_antihackeo_pct, seguro_dinero_pct, nivel_soporte, impuesto_pct, orden) VALUES
  ('basica',     0,      5,  2,  55000,  100000,  65000,       0,  0,  0, 'normal',    25, 1),
  ('gold',       75000,  10, 5,  60000,  150000,  75000,       0, 20, 40, 'vt',        22, 2),
  ('zafiro',     125000, 15, 10, 75000,  175000,  95000,       0, 40, 45, 'vt',        20, 3),
  ('esmeralda',  300000, 25, 15, 100000, 200000,  115000,      0, 45, 50, 'vp',        18, 4),
  ('diamond',    350000, 35, 25, 185000, 275000,  175000, 145000, 50, 60, 'vp',        15, 5),
  ('ruby',       500000, 45, 30, 185000, 450000,  350000, 175000, 70, 75, 'plus',      12, 6),
  ('ruby_plus',  600000, -1, 100,250000, 1400000, 500000, 450000, 100,100,'plus_plus', 10, 7)
ON CONFLICT (tipo) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.config_sueldos (
  role public.app_role PRIMARY KEY,
  monto numeric NOT NULL DEFAULT 0,
  dias_periodo int NOT NULL DEFAULT 7,
  activo boolean NOT NULL DEFAULT true
);
ALTER TABLE public.config_sueldos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "lectura config_sueldos" ON public.config_sueldos;
CREATE POLICY "lectura config_sueldos" ON public.config_sueldos FOR SELECT USING (true);
DROP POLICY IF EXISTS "admin edita config_sueldos" ON public.config_sueldos;
CREATE POLICY "admin edita config_sueldos" ON public.config_sueldos FOR ALL
  USING (public.has_role('admin')) WITH CHECK (public.has_role('admin'));

INSERT INTO public.config_sueldos (role, monto, dias_periodo, activo) VALUES
  ('policia',     50000, 7, true),
  ('trabajador',  75000, 7, true),
  ('admin',       0,     7, false)
ON CONFLICT (role) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.sueldos_reclamados (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL,
  role public.app_role NOT NULL,
  monto numeric NOT NULL,
  fecha timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sueldos_usuario_fecha ON public.sueldos_reclamados(usuario_id, role, fecha DESC);
ALTER TABLE public.sueldos_reclamados ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ver sueldos propios o staff" ON public.sueldos_reclamados;
CREATE POLICY "ver sueldos propios o staff" ON public.sueldos_reclamados FOR SELECT
  USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));

CREATE TABLE IF NOT EXISTS public.multas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL,
  policia_id uuid,
  monto numeric NOT NULL CHECK (monto > 0),
  motivo text NOT NULL,
  estado public.estado_multa NOT NULL DEFAULT 'pendiente',
  fecha_emision timestamptz NOT NULL DEFAULT now(),
  fecha_pago timestamptz,
  ultimo_recordatorio timestamptz
);
CREATE INDEX IF NOT EXISTS idx_multas_usuario ON public.multas(usuario_id, estado);
CREATE INDEX IF NOT EXISTS idx_multas_estado ON public.multas(estado);
ALTER TABLE public.multas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ver multas propias o staff" ON public.multas;
CREATE POLICY "ver multas propias o staff" ON public.multas FOR SELECT
  USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador') OR public.has_role('policia'));

CREATE OR REPLACE FUNCTION public.emitir_multa(_usuario_id uuid, _monto numeric, _motivo text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE staff uuid := public.current_usuario_id(); mid uuid; u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('policia') OR public.has_role('admin')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto invalido'; END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 3 THEN RAISE EXCEPTION 'Motivo requerido'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  INSERT INTO multas(usuario_id, policia_id, monto, motivo) VALUES (_usuario_id, staff, _monto, _motivo) RETURNING id INTO mid;
  PERFORM public.log_audit('EMITIR_MULTA','multa', mid, u.nombre, jsonb_build_object('monto', _monto, 'motivo', _motivo));
  RETURN mid;
END $$;

CREATE OR REPLACE FUNCTION public.pagar_multa(_multa_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); m multas%ROWTYPE; u usuarios%ROWTYPE;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT * INTO m FROM multas WHERE id = _multa_id FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Multa no encontrada'; END IF;
  IF m.usuario_id <> uid THEN RAISE EXCEPTION 'No es tu multa'; END IF;
  IF m.estado <> 'pendiente' THEN RAISE EXCEPTION 'Multa ya resuelta'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = uid FOR UPDATE;
  IF u.saldo_banco < m.monto THEN RAISE EXCEPTION 'Saldo banco insuficiente'; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - m.monto WHERE id = uid;
  UPDATE multas SET estado='pagada', fecha_pago=now() WHERE id = m.id;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (uid, 'pago_multa'::tipo_movimiento, m.monto, 'Pago de multa: ' || m.motivo);
  PERFORM public.registrar_ganancia('multa', uid, m.monto);
END $$;

CREATE OR REPLACE FUNCTION public.cancelar_multa(_multa_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m multas%ROWTYPE; u usuarios%ROWTYPE;
BEGIN
  IF NOT (public.has_role('policia') OR public.has_role('admin')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO m FROM multas WHERE id = _multa_id FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Multa no encontrada'; END IF;
  IF m.estado <> 'pendiente' THEN RAISE EXCEPTION 'Multa ya resuelta'; END IF;
  UPDATE multas SET estado='cancelada', fecha_pago=now() WHERE id = m.id;
  SELECT * INTO u FROM usuarios WHERE id = m.usuario_id;
  PERFORM public.log_audit('CANCELAR_MULTA','multa', m.id, u.nombre, jsonb_build_object('motivo', _motivo));
END $$;

CREATE OR REPLACE FUNCTION public.marcar_recordatorio_multa(_multa_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_role('policia') OR public.has_role('admin')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  UPDATE multas SET ultimo_recordatorio = now() WHERE id = _multa_id;
END $$;

CREATE OR REPLACE FUNCTION public.reclamar_sueldo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := public.current_usuario_id();
  v_role public.app_role;
  v_monto numeric;
  v_dias int;
  ultimo timestamptz;
  owner uuid;
  owner_saldo numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT r.role, c.monto, c.dias_periodo INTO v_role, v_monto, v_dias
  FROM roles_usuario r
  JOIN config_sueldos c ON c.role = r.role
  WHERE r.usuario_id = uid AND c.activo = true AND c.monto > 0
  ORDER BY c.monto DESC LIMIT 1;
  IF v_role IS NULL THEN RAISE EXCEPTION 'No tienes un rol con sueldo asignado'; END IF;
  SELECT max(fecha) INTO ultimo FROM sueldos_reclamados WHERE usuario_id = uid AND role = v_role;
  IF ultimo IS NOT NULL AND (now() - ultimo) < (v_dias || ' days')::interval THEN
    RAISE EXCEPTION 'Aun no puedes reclamar. Proximo: %', (ultimo + (v_dias || ' days')::interval);
  END IF;
  owner := public.dueno_usuario_id();
  IF owner IS NULL THEN RAISE EXCEPTION 'Gobierno sin dueno configurado'; END IF;
  SELECT saldo_banco INTO owner_saldo FROM usuarios WHERE id = owner FOR UPDATE;
  IF owner_saldo < v_monto THEN RAISE EXCEPTION 'Gobierno sin fondos suficientes'; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - v_monto WHERE id = owner;
  UPDATE usuarios SET saldo_banco = saldo_banco + v_monto WHERE id = uid;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES
    (owner, 'admin_quitar'::tipo_movimiento, v_monto, 'Sueldo pagado a ' || v_role::text),
    (uid,   'sueldo'::tipo_movimiento, v_monto, 'Sueldo de ' || v_role::text);
  INSERT INTO sueldos_reclamados(usuario_id, role, monto) VALUES (uid, v_role, v_monto);
  RETURN jsonb_build_object('monto', v_monto, 'role', v_role, 'proximo', now() + (v_dias || ' days')::interval);
END $$;

CREATE OR REPLACE FUNCTION public.proximo_sueldo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := public.current_usuario_id();
  v_role public.app_role; v_monto numeric; v_dias int; ultimo timestamptz;
BEGIN
  IF uid IS NULL THEN RETURN NULL; END IF;
  SELECT r.role, c.monto, c.dias_periodo INTO v_role, v_monto, v_dias
  FROM roles_usuario r
  JOIN config_sueldos c ON c.role = r.role
  WHERE r.usuario_id = uid AND c.activo = true AND c.monto > 0
  ORDER BY c.monto DESC LIMIT 1;
  IF v_role IS NULL THEN RETURN NULL; END IF;
  SELECT max(fecha) INTO ultimo FROM sueldos_reclamados WHERE usuario_id = uid AND role = v_role;
  RETURN jsonb_build_object(
    'role', v_role, 'monto', v_monto, 'dias_periodo', v_dias, 'ultimo', ultimo,
    'disponible', ultimo IS NULL OR (now() - ultimo) >= (v_dias || ' days')::interval,
    'proximo', CASE WHEN ultimo IS NULL THEN now() ELSE ultimo + (v_dias || ' days')::interval END
  );
END $$;

CREATE OR REPLACE FUNCTION public.comprar_membresia(_tipo public.tipo_membresia)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); u usuarios%ROWTYPE; cfg config_membresias%ROWTYPE; owner uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT * INTO cfg FROM config_membresias WHERE tipo = _tipo;
  IF cfg.tipo IS NULL THEN RAISE EXCEPTION 'Membresia invalida'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = uid FOR UPDATE;
  IF u.estado_cuenta <> 'activa' THEN RAISE EXCEPTION 'Cuenta no activa'; END IF;
  IF u.membresia = _tipo THEN RAISE EXCEPTION 'Ya tienes esta membresia'; END IF;
  IF cfg.costo > 0 THEN
    IF u.saldo_banco < cfg.costo THEN RAISE EXCEPTION 'Saldo banco insuficiente'; END IF;
    UPDATE usuarios SET saldo_banco = saldo_banco - cfg.costo WHERE id = uid;
    INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (uid, 'compra_membresia'::tipo_movimiento, cfg.costo, 'Compra membresia ' || _tipo::text);
    owner := public.dueno_usuario_id();
    IF owner IS NOT NULL THEN
      UPDATE usuarios SET saldo_banco = saldo_banco + cfg.costo WHERE id = owner;
      INSERT INTO ganancias_banco(concepto, usuario_id, monto) VALUES ('compra_membresia', uid, cfg.costo);
      INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (owner, 'ganancia_banco'::tipo_movimiento, cfg.costo, 'Ingreso membresia ' || _tipo::text);
    END IF;
  END IF;
  UPDATE usuarios SET membresia = _tipo WHERE id = uid;
  INSERT INTO membresias(usuario_id, tipo, fecha_inicio, fecha_renovacion, activa)
    VALUES (uid, _tipo, now(), now() + interval '30 days', true);
  PERFORM public.log_audit('COMPRA_MEMBRESIA','usuario', uid, u.nombre, jsonb_build_object('tipo', _tipo, 'costo', cfg.costo));
  RETURN jsonb_build_object('tipo', _tipo, 'role_id_discord', cfg.role_id_discord);
END $$;

CREATE OR REPLACE FUNCTION public.cobrar_impuestos_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; cobrado_total numeric := 0; n int := 0; debido numeric; tomar numeric; faltante numeric; owner uuid;
BEGIN
  owner := public.dueno_usuario_id();
  FOR r IN
    SELECT u.id, u.saldo_banco, u.impuestos_pendientes, c.impuesto_pct
    FROM usuarios u
    JOIN config_membresias c ON c.tipo = u.membresia
    WHERE u.estado_cuenta = 'activa'
      AND (u.ultimo_impuesto_en IS NULL OR (now() - u.ultimo_impuesto_en) >= interval '6 days')
  LOOP
    debido := round((r.saldo_banco * r.impuesto_pct / 100)::numeric, 2);
    IF debido <= 0 THEN
      UPDATE usuarios SET ultimo_impuesto_en = now() WHERE id = r.id;
      CONTINUE;
    END IF;
    tomar := LEAST(debido, r.saldo_banco);
    faltante := debido - tomar;
    UPDATE usuarios SET saldo_banco = saldo_banco - tomar,
                       impuestos_pendientes = impuestos_pendientes + faltante,
                       ultimo_impuesto_en = now()
      WHERE id = r.id;
    IF tomar > 0 THEN
      INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (r.id, 'impuesto'::tipo_movimiento, tomar, 'Impuesto (' || r.impuesto_pct || '%)');
      INSERT INTO ganancias_banco(concepto, usuario_id, monto) VALUES ('impuesto', r.id, tomar);
      IF owner IS NOT NULL THEN
        UPDATE usuarios SET saldo_banco = saldo_banco + tomar WHERE id = owner;
      END IF;
      cobrado_total := cobrado_total + tomar;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('procesados', n, 'cobrado_total', cobrado_total);
END $$;

CREATE OR REPLACE FUNCTION public.check_limite_transaccion(_usuario_id uuid, _monto numeric)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE u usuarios%ROWTYPE; cfg config_membresias%ROWTYPE; tx_hoy int; tx_grandes_hoy int;
BEGIN
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  SELECT * INTO cfg FROM config_membresias WHERE tipo = u.membresia;
  IF cfg.tipo IS NULL THEN RETURN; END IF;
  SELECT count(*), count(*) FILTER (WHERE monto >= cfg.monto_grande)
    INTO tx_hoy, tx_grandes_hoy
    FROM movimientos
    WHERE usuario_id = _usuario_id
      AND tipo IN ('transferencia_enviada','retiro','deposito')
      AND fecha >= date_trunc('day', now());
  IF cfg.tx_diarias >= 0 AND tx_hoy >= cfg.tx_diarias THEN
    RAISE EXCEPTION 'Limite diario de transacciones alcanzado (% / membresia %)', cfg.tx_diarias, u.membresia;
  END IF;
  IF _monto >= cfg.monto_grande AND tx_grandes_hoy >= cfg.tx_grandes_diarias THEN
    RAISE EXCEPTION 'Limite de transacciones grandes alcanzado (% / membresia %)', cfg.tx_grandes_diarias, u.membresia;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.op_transferir(_destino_numero text, _monto numeric, _concepto text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); destino usuarios%ROWTYPE; origen usuarios%ROWTYPE; pct numeric; comision numeric; total numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto invalido'; END IF;
  PERFORM public.check_limite_transaccion(uid, _monto);
  SELECT * INTO destino FROM usuarios WHERE numero_cliente = _destino_numero OR clabe = _destino_numero;
  IF destino.id IS NULL THEN RAISE EXCEPTION 'Cliente destino no existe'; END IF;
  IF destino.id = uid THEN RAISE EXCEPTION 'No puedes transferirte a ti mismo'; END IF;
  IF destino.estado_cuenta <> 'activa' THEN RAISE EXCEPTION 'Cuenta destino no activa'; END IF;
  SELECT comision_porcentaje INTO pct FROM config WHERE id = 1;
  pct := COALESCE(pct, 0);
  comision := round((_monto * pct / 100)::numeric, 2);
  total := _monto + comision;
  SELECT * INTO origen FROM usuarios WHERE id = uid FOR UPDATE;
  IF origen.estado_cuenta <> 'activa' THEN RAISE EXCEPTION 'Tu cuenta no esta activa'; END IF;
  IF origen.saldo_banco < total THEN RAISE EXCEPTION 'Saldo insuficiente. Necesitas %', total; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - total WHERE id = uid;
  UPDATE usuarios SET saldo_banco = saldo_banco + _monto WHERE id = destino.id;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion, contraparte_id)
    VALUES (uid, 'transferencia_enviada', _monto, 'A ' || destino.nombre || ' (' || destino.numero_cliente || ')' || CASE WHEN _concepto IS NOT NULL AND length(_concepto)>0 THEN ' - '||_concepto ELSE '' END, destino.id);
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion, contraparte_id)
    VALUES (destino.id, 'transferencia_recibida', _monto, 'De ' || origen.nombre || ' (' || origen.numero_cliente || ')' || CASE WHEN _concepto IS NOT NULL AND length(_concepto)>0 THEN ' - '||_concepto ELSE '' END, uid);
  IF comision > 0 THEN
    INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'comision', comision, 'Comision por transferencia');
    PERFORM public.registrar_ganancia('comision_transferencia', uid, comision);
  END IF;
  RETURN jsonb_build_object('monto', _monto, 'comision', comision, 'total', total, 'destino_nombre', destino.nombre, 'destino_numero', destino.numero_cliente, 'destino_id', destino.id);
END $$;
