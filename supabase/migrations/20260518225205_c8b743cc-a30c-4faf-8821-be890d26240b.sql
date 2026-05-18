
-- ENUMS
CREATE TYPE public.app_role AS ENUM ('admin', 'trabajador', 'usuario');
CREATE TYPE public.tipo_movimiento AS ENUM ('deposito', 'retiro', 'transferencia_enviada', 'transferencia_recibida', 'comision', 'pago_credito', 'uso_credito', 'interes_credito', 'membresia', 'admin_dar', 'admin_quitar', 'condonacion', 'ganancia_banco');
CREATE TYPE public.tipo_membresia AS ENUM ('basica', 'plus', 'black');
CREATE TYPE public.estado_solicitud AS ENUM ('pendiente', 'aprobada', 'rechazada');
CREATE TYPE public.estado_credito AS ENUM ('sin_solicitar', 'pendiente', 'activa', 'bloqueada', 'rechazada');

CREATE TABLE public.usuarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  discord_id TEXT NOT NULL UNIQUE,
  discord_username TEXT NOT NULL,
  discord_avatar_url TEXT,
  nombre TEXT NOT NULL,
  numero_cliente TEXT NOT NULL UNIQUE,
  saldo_cartera NUMERIC(14,2) NOT NULL DEFAULT 0,
  saldo_banco NUMERIC(14,2) NOT NULL DEFAULT 0,
  nip_hash TEXT,
  membresia public.tipo_membresia NOT NULL DEFAULT 'basica',
  intentos_fallidos INT NOT NULL DEFAULT 0,
  bloqueado_hasta TIMESTAMPTZ,
  fecha_registro TIMESTAMPTZ NOT NULL DEFAULT now(),
  auth_user_id UUID UNIQUE
);
ALTER TABLE public.usuarios ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.roles_usuario (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE(usuario_id, role)
);
ALTER TABLE public.roles_usuario ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.current_usuario_id()
RETURNS UUID LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.has_role(_role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.roles_usuario r
    JOIN public.usuarios u ON u.id = r.usuario_id
    WHERE u.auth_user_id = auth.uid() AND r.role = _role
  )
$$;

CREATE TABLE public.movimientos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  tipo public.tipo_movimiento NOT NULL,
  monto NUMERIC(14,2) NOT NULL,
  descripcion TEXT NOT NULL,
  contraparte_id UUID REFERENCES public.usuarios(id),
  fecha TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_movimientos_usuario ON public.movimientos(usuario_id, fecha DESC);
ALTER TABLE public.movimientos ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.tarjetas_debito (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL UNIQUE REFERENCES public.usuarios(id) ON DELETE CASCADE,
  numero TEXT NOT NULL,
  cvv TEXT NOT NULL,
  vencimiento TEXT NOT NULL,
  congelada BOOLEAN NOT NULL DEFAULT false,
  creada_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.tarjetas_debito ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.tarjetas_credito (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL UNIQUE REFERENCES public.usuarios(id) ON DELETE CASCADE,
  numero TEXT,
  cvv TEXT,
  vencimiento TEXT,
  limite NUMERIC(14,2) NOT NULL DEFAULT 5000,
  saldo_usado NUMERIC(14,2) NOT NULL DEFAULT 0,
  nivel INT NOT NULL DEFAULT 1,
  estado public.estado_credito NOT NULL DEFAULT 'sin_solicitar',
  fecha_uso TIMESTAMPTZ,
  fecha_limite_pago TIMESTAMPTZ,
  dias_vencidos INT NOT NULL DEFAULT 0,
  pagos_a_tiempo INT NOT NULL DEFAULT 0,
  score INT NOT NULL DEFAULT 50
);
ALTER TABLE public.tarjetas_credito ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.solicitudes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  tipo TEXT NOT NULL,
  estado public.estado_solicitud NOT NULL DEFAULT 'pendiente',
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  resuelta_en TIMESTAMPTZ,
  resuelta_por UUID REFERENCES public.usuarios(id)
);
ALTER TABLE public.solicitudes ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.membresias (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  tipo public.tipo_membresia NOT NULL,
  fecha_inicio TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_renovacion TIMESTAMPTZ NOT NULL,
  activa BOOLEAN NOT NULL DEFAULT true
);
ALTER TABLE public.membresias ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.config (
  id INT PRIMARY KEY DEFAULT 1,
  dueno_discord_id TEXT,
  comision_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 1.5,
  interes_diario_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 5.0,
  costo_membresia_plus NUMERIC(14,2) NOT NULL DEFAULT 75000,
  costo_membresia_black NUMERIC(14,2) NOT NULL DEFAULT 350000,
  CONSTRAINT singleton CHECK (id = 1)
);
INSERT INTO public.config (id) VALUES (1);
ALTER TABLE public.config ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.ganancias_banco (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  concepto TEXT NOT NULL,
  usuario_id UUID REFERENCES public.usuarios(id),
  monto NUMERIC(14,2) NOT NULL,
  fecha TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ganancias_fecha ON public.ganancias_banco(fecha DESC);
ALTER TABLE public.ganancias_banco ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.login_codigos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  discord_id TEXT NOT NULL,
  codigo_hash TEXT NOT NULL,
  intentos INT NOT NULL DEFAULT 0,
  expira_en TIMESTAMPTZ NOT NULL,
  usado BOOLEAN NOT NULL DEFAULT false,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_login_codigos_discord ON public.login_codigos(discord_id, creado_en DESC);
ALTER TABLE public.login_codigos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuarios ven su propio perfil" ON public.usuarios FOR SELECT USING (auth_user_id = auth.uid() OR public.has_role('admin') OR public.has_role('trabajador'));
CREATE POLICY "Usuarios editan su propio perfil" ON public.usuarios FOR UPDATE USING (auth_user_id = auth.uid() OR public.has_role('admin'));
CREATE POLICY "Admin inserta usuarios" ON public.usuarios FOR INSERT WITH CHECK (public.has_role('admin'));

CREATE POLICY "Lectura roles propios o admin" ON public.roles_usuario FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin'));
CREATE POLICY "Admin gestiona roles" ON public.roles_usuario FOR ALL USING (public.has_role('admin')) WITH CHECK (public.has_role('admin'));

CREATE POLICY "Ver movimientos propios o staff" ON public.movimientos FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));

CREATE POLICY "Ver tarjeta propia o staff" ON public.tarjetas_debito FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));
CREATE POLICY "Editar tarjeta propia" ON public.tarjetas_debito FOR UPDATE USING (usuario_id = public.current_usuario_id());

CREATE POLICY "Ver credito propio o staff" ON public.tarjetas_credito FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));

CREATE POLICY "Ver solicitudes propias o staff" ON public.solicitudes FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));
CREATE POLICY "Crear solicitudes propias" ON public.solicitudes FOR INSERT WITH CHECK (usuario_id = public.current_usuario_id());

CREATE POLICY "Ver membresias propias o staff" ON public.membresias FOR SELECT USING (usuario_id = public.current_usuario_id() OR public.has_role('admin') OR public.has_role('trabajador'));

CREATE POLICY "Lectura config staff" ON public.config FOR SELECT USING (public.has_role('admin') OR public.has_role('trabajador'));
CREATE POLICY "Admin edita config" ON public.config FOR UPDATE USING (public.has_role('admin'));

CREATE POLICY "Staff ve ganancias" ON public.ganancias_banco FOR SELECT USING (public.has_role('admin') OR public.has_role('trabajador'));

CREATE OR REPLACE FUNCTION public.generar_numero_cliente()
RETURNS TEXT LANGUAGE plpgsql SET search_path = public AS $$
DECLARE num TEXT;
BEGIN
  num := 'BMX' || lpad((floor(random()*9999999)::int)::text, 7, '0');
  RETURN num;
END;
$$;

CREATE OR REPLACE FUNCTION public.crear_tarjeta_debito_inicial()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE num TEXT; cvv TEXT; venc TEXT;
BEGIN
  num := '4' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  cvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  INSERT INTO public.tarjetas_debito(usuario_id, numero, cvv, vencimiento) VALUES (NEW.id, num, cvv, venc);
  INSERT INTO public.roles_usuario(usuario_id, role) VALUES (NEW.id, 'usuario');
  INSERT INTO public.tarjetas_credito(usuario_id, estado) VALUES (NEW.id, 'sin_solicitar');
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_crear_tarjeta_debito AFTER INSERT ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.crear_tarjeta_debito_inicial();

REVOKE EXECUTE ON FUNCTION public.crear_tarjeta_debito_inicial() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.current_usuario_id() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.has_role(public.app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_usuario_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_role(public.app_role) TO authenticated;

CREATE OR REPLACE FUNCTION public.dueno_usuario_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id FROM public.usuarios u JOIN public.config c ON c.id = 1 WHERE u.discord_id = c.dueno_discord_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.registrar_ganancia(_concepto text, _usuario uuid, _monto numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE owner_id uuid;
BEGIN
  IF _monto IS NULL OR _monto <= 0 THEN RETURN; END IF;
  INSERT INTO public.ganancias_banco(concepto, usuario_id, monto) VALUES (_concepto, _usuario, _monto);
  owner_id := public.dueno_usuario_id();
  IF owner_id IS NOT NULL THEN
    UPDATE public.usuarios SET saldo_banco = saldo_banco + _monto WHERE id = owner_id;
    INSERT INTO public.movimientos(usuario_id, tipo, monto, descripcion) VALUES (owner_id, 'ganancia_banco', _monto, 'Ganancia: ' || _concepto);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.op_depositar(_monto numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); cartera numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT saldo_cartera INTO cartera FROM usuarios WHERE id = uid FOR UPDATE;
  IF cartera < _monto THEN RAISE EXCEPTION 'Saldo insuficiente en cartera'; END IF;
  UPDATE usuarios SET saldo_cartera = saldo_cartera - _monto, saldo_banco = saldo_banco + _monto WHERE id = uid;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'deposito', _monto, 'Depósito a cuenta');
END;
$$;

CREATE OR REPLACE FUNCTION public.op_retirar(_monto numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); banco numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT saldo_banco INTO banco FROM usuarios WHERE id = uid FOR UPDATE;
  IF banco < _monto THEN RAISE EXCEPTION 'Saldo insuficiente en banco'; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - _monto, saldo_cartera = saldo_cartera + _monto WHERE id = uid;
  INSERT INTO movimientos (usuario_id, tipo, monto, descripcion) VALUES (uid, 'retiro', _monto, 'Retiro a cartera');
END;
$$;

CREATE OR REPLACE FUNCTION public.op_transferir(_destino_numero text, _monto numeric, _concepto text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); destino usuarios%ROWTYPE; origen usuarios%ROWTYPE; pct numeric; comision numeric; total numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  IF _destino_numero IS NULL OR length(_destino_numero) = 0 THEN RAISE EXCEPTION 'Destino requerido'; END IF;
  SELECT * INTO destino FROM usuarios WHERE numero_cliente = _destino_numero;
  IF destino.id IS NULL THEN RAISE EXCEPTION 'Cliente destino no existe'; END IF;
  IF destino.id = uid THEN RAISE EXCEPTION 'No puedes transferirte a ti mismo'; END IF;
  SELECT comision_porcentaje INTO pct FROM config WHERE id = 1;
  pct := COALESCE(pct, 0);
  comision := round((_monto * pct / 100)::numeric, 2);
  total := _monto + comision;
  SELECT * INTO origen FROM usuarios WHERE id = uid FOR UPDATE;
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
  RETURN jsonb_build_object('monto', _monto, 'comision', comision, 'total', total, 'destino_nombre', destino.nombre, 'destino_numero', destino.numero_cliente);
END;
$$;

CREATE OR REPLACE FUNCTION public.toggle_tarjeta_debito()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); nuevo boolean;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  UPDATE tarjetas_debito SET congelada = NOT congelada WHERE usuario_id = uid RETURNING congelada INTO nuevo;
  RETURN nuevo;
END;
$$;

CREATE OR REPLACE FUNCTION public.solicitar_tarjeta_credito()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); tc tarjetas_credito%ROWTYPE; sol_id uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = uid;
  IF tc.id IS NULL THEN
    INSERT INTO tarjetas_credito(usuario_id, estado) VALUES (uid, 'pendiente') RETURNING id INTO tc.id;
  ELSE
    IF tc.estado IN ('pendiente','activa') THEN RAISE EXCEPTION 'Ya tienes una solicitud o tarjeta activa'; END IF;
    UPDATE tarjetas_credito SET estado='pendiente' WHERE id = tc.id;
  END IF;
  INSERT INTO solicitudes(usuario_id, tipo, estado) VALUES (uid, 'tarjeta_credito', 'pendiente') RETURNING id INTO sol_id;
  RETURN sol_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.aprobar_tarjeta_credito(_solicitud_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE staff uuid := public.current_usuario_id(); s solicitudes%ROWTYPE; tc tarjetas_credito%ROWTYPE; num text; ncvv text; venc text;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO s FROM solicitudes WHERE id = _solicitud_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF s.tipo <> 'tarjeta_credito' THEN RAISE EXCEPTION 'Tipo de solicitud no es tarjeta_credito (%)', s.tipo; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'Solicitud ya resuelta (%)', s.estado; END IF;
  num  := '5' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  ncvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = s.usuario_id FOR UPDATE;
  IF tc.id IS NULL THEN
    INSERT INTO tarjetas_credito(usuario_id, estado, numero, cvv, vencimiento, limite) VALUES (s.usuario_id, 'activa', num, ncvv, venc, 5000);
  ELSE
    UPDATE tarjetas_credito SET estado='activa', numero=num, cvv=ncvv, vencimiento=venc, limite = COALESCE(NULLIF(limite,0), 5000) WHERE id = tc.id;
  END IF;
  UPDATE solicitudes SET estado='aprobada', resuelta_por=staff, resuelta_en=now() WHERE id=s.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rechazar_tarjeta_credito(_solicitud_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE staff uuid := public.current_usuario_id(); s solicitudes%ROWTYPE;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO s FROM solicitudes WHERE id = _solicitud_id FOR UPDATE;
  IF s.id IS NULL OR s.tipo <> 'tarjeta_credito' THEN RAISE EXCEPTION 'Solicitud inválida'; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'Solicitud ya resuelta'; END IF;
  UPDATE tarjetas_credito SET estado='rechazada' WHERE usuario_id = s.usuario_id;
  UPDATE solicitudes SET estado='rechazada', resuelta_por=staff, resuelta_en=now() WHERE id=s.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.usar_credito(_monto numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); tc tarjetas_credito%ROWTYPE; disponible numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = uid FOR UPDATE;
  IF tc.id IS NULL OR tc.estado <> 'activa' THEN RAISE EXCEPTION 'No tienes tarjeta de crédito activa'; END IF;
  disponible := tc.limite - tc.saldo_usado;
  IF _monto > disponible THEN RAISE EXCEPTION 'Excede tu límite disponible (%)', disponible; END IF;
  UPDATE tarjetas_credito SET saldo_usado = saldo_usado + _monto, fecha_uso = COALESCE(fecha_uso, now()), fecha_limite_pago = COALESCE(fecha_limite_pago, now() + interval '6 days') WHERE id = tc.id;
  UPDATE usuarios SET saldo_banco = saldo_banco + _monto WHERE id = uid;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (uid, 'uso_credito', _monto, 'Uso de crédito');
END;
$$;

CREATE OR REPLACE FUNCTION public.pagar_credito(_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := public.current_usuario_id(); tc tarjetas_credito%ROWTYPE; u usuarios%ROWTYPE; pago numeric; liquidada boolean := false;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
  SELECT * INTO tc FROM tarjetas_credito WHERE usuario_id = uid FOR UPDATE;
  IF tc.id IS NULL OR tc.saldo_usado <= 0 THEN RAISE EXCEPTION 'No tienes deuda'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = uid FOR UPDATE;
  pago := LEAST(_monto, tc.saldo_usado);
  IF u.saldo_banco < pago THEN RAISE EXCEPTION 'Saldo insuficiente en banco'; END IF;
  UPDATE usuarios SET saldo_banco = saldo_banco - pago WHERE id = uid;
  UPDATE tarjetas_credito SET saldo_usado = saldo_usado - pago WHERE id = tc.id;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (uid, 'pago_credito', pago, 'Pago a tarjeta de crédito');
  IF (tc.saldo_usado - pago) <= 0 THEN
    liquidada := true;
    UPDATE tarjetas_credito SET fecha_uso = NULL, fecha_limite_pago = NULL, dias_vencidos = 0, pagos_a_tiempo = pagos_a_tiempo + 1, score = LEAST(100, score + 5), estado = CASE WHEN estado='bloqueada' THEN 'activa' ELSE estado END WHERE id = tc.id;
  END IF;
  RETURN jsonb_build_object('pagado', pago, 'liquidada', liquidada);
END;
$$;

CREATE OR REPLACE FUNCTION public.ajustar_limite_credito(_usuario_id uuid, _nuevo_limite numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  IF _nuevo_limite < 0 OR _nuevo_limite > 10000000 THEN RAISE EXCEPTION 'Límite inválido'; END IF;
  UPDATE tarjetas_credito SET limite = _nuevo_limite WHERE usuario_id = _usuario_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.condonar_deuda(_usuario_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE deuda numeric;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT saldo_usado INTO deuda FROM tarjetas_credito WHERE usuario_id = _usuario_id FOR UPDATE;
  IF deuda IS NULL OR deuda <= 0 THEN RAISE EXCEPTION 'Sin deuda que condonar'; END IF;
  UPDATE tarjetas_credito SET saldo_usado = 0, fecha_uso = NULL, fecha_limite_pago = NULL, dias_vencidos = 0, estado = CASE WHEN estado='bloqueada' THEN 'activa' ELSE estado END WHERE usuario_id = _usuario_id;
  INSERT INTO movimientos(usuario_id, tipo, monto, descripcion) VALUES (_usuario_id, 'condonacion', deuda, 'Deuda condonada');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ajustar_saldo(_usuario_id uuid, _delta numeric, _cuenta text, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END;
$$;

CREATE OR REPLACE FUNCTION public.set_dueno_banco(_discord_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE clean text := NULLIF(trim(_discord_id), '');
BEGIN
  IF NOT public.has_role('admin') THEN RAISE EXCEPTION 'Solo admin'; END IF;
  IF clean IS NULL THEN UPDATE config SET dueno_discord_id = NULL WHERE id = 1; RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM usuarios WHERE discord_id = clean) THEN RAISE EXCEPTION 'Ese Discord ID no está registrado en el banco'; END IF;
  UPDATE config SET dueno_discord_id = clean WHERE id = 1;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.op_depositar(numeric) FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.op_retirar(numeric) FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.op_transferir(text, numeric, text) FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.toggle_tarjeta_debito() FROM anon, authenticated, public;
