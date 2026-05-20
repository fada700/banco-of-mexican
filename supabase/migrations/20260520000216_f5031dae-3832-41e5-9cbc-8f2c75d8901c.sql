
-- 1) WIPE de datos
TRUNCATE TABLE public.audit_logs, public.notification_log, public.movimientos,
  public.ganancias_banco, public.solicitudes, public.login_codigos,
  public.membresias, public.tarjetas_credito, public.tarjetas_debito,
  public.roles_usuario, public.usuarios RESTART IDENTITY CASCADE;

-- Borrar usuarios de auth
DELETE FROM auth.users;

-- 2) Función reabrir_cuenta
CREATE OR REPLACE FUNCTION public.reabrir_cuenta(_usuario_id uuid, _motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE u usuarios%ROWTYPE; antes public.estado_cuenta_general;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF u.estado_cuenta = 'activa' THEN RAISE EXCEPTION 'La cuenta ya está activa'; END IF;
  antes := u.estado_cuenta;
  UPDATE usuarios SET estado_cuenta = 'activa' WHERE id = u.id;
  UPDATE tarjetas_debito SET estado = 'activa', congelada = false WHERE usuario_id = u.id;
  PERFORM public.log_audit('REABRIR_CUENTA','usuario', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'antes', antes, 'despues', 'activa'));
END $$;

GRANT EXECUTE ON FUNCTION public.reabrir_cuenta(uuid, text) TO authenticated;

-- 3) Fix cerrar_cuenta: prevenir doble cierre y registrar antes correcto
CREATE OR REPLACE FUNCTION public.cerrar_cuenta(_usuario_id uuid, _motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE u usuarios%ROWTYPE; antes public.estado_cuenta_general;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  IF u.estado_cuenta = 'cerrada' THEN RAISE EXCEPTION 'La cuenta ya está cerrada'; END IF;
  antes := u.estado_cuenta;
  UPDATE usuarios SET estado_cuenta = 'cerrada' WHERE id = u.id;
  UPDATE tarjetas_debito SET estado = 'cerrada', congelada = true WHERE usuario_id = u.id;
  UPDATE tarjetas_credito SET estado = 'cerrada' WHERE usuario_id = u.id;
  PERFORM public.log_audit('CERRAR_CUENTA','usuario', u.id, u.nombre,
    jsonb_build_object('motivo', _motivo, 'antes', antes, 'despues', 'cerrada'));
END $$;
