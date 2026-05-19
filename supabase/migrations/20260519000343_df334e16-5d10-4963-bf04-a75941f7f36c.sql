GRANT EXECUTE ON FUNCTION public.toggle_tarjeta_debito() TO authenticated;
GRANT EXECUTE ON FUNCTION public.op_depositar(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.op_retirar(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.op_transferir(text, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.solicitar_tarjeta_credito()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := public.current_usuario_id();
  est public.estado_cuenta_general;
  tc tarjetas_credito%ROWTYPE;
  sol_id uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT estado_cuenta INTO est FROM usuarios WHERE id = uid;
  IF est = 'congelada' THEN RAISE EXCEPTION 'Tu cuenta está congelada. Contacta soporte.'; END IF;
  IF est = 'cerrada'  THEN RAISE EXCEPTION 'Tu cuenta está cerrada. No puedes solicitar tarjetas.'; END IF;

  IF EXISTS(SELECT 1 FROM solicitudes WHERE usuario_id = uid AND tipo='tarjeta_credito' AND estado='pendiente') THEN
    RAISE EXCEPTION 'Ya tienes una solicitud pendiente';
  END IF;

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

CREATE INDEX IF NOT EXISTS idx_movimientos_usuario_fecha ON public.movimientos(usuario_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_movimientos_fecha ON public.movimientos(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_fecha ON public.audit_logs(fecha_hora DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_realizado_por ON public.audit_logs(realizado_por_id);
CREATE INDEX IF NOT EXISTS idx_solicitudes_estado_fecha ON public.solicitudes(estado, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_usuarios_numero_cliente ON public.usuarios(numero_cliente);
CREATE INDEX IF NOT EXISTS idx_usuarios_discord_id ON public.usuarios(discord_id);
CREATE INDEX IF NOT EXISTS idx_tarjetas_credito_usuario ON public.tarjetas_credito(usuario_id);
CREATE INDEX IF NOT EXISTS idx_tarjetas_debito_usuario ON public.tarjetas_debito(usuario_id);
CREATE INDEX IF NOT EXISTS idx_notification_log_usuario ON public.notification_log(usuario_id, enviado_en DESC);