
-- Fix admin_ajustar_saldo: cast tipo to enum
CREATE OR REPLACE FUNCTION public.admin_ajustar_saldo(_usuario_id uuid, _delta numeric, _cuenta text, _motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
    VALUES (u.id,
            (CASE WHEN _delta > 0 THEN 'admin_dar' ELSE 'admin_quitar' END)::tipo_movimiento,
            abs(_delta),
            'Admin (' || _cuenta || ')' || CASE WHEN _motivo IS NOT NULL AND length(_motivo)>0 THEN ' — '||_motivo ELSE '' END);
  PERFORM public.log_audit(CASE WHEN _delta > 0 THEN 'ADD_BALANCE' ELSE 'REMOVE_BALANCE' END,
    'usuario', u.id, u.nombre,
    jsonb_build_object('cuenta', _cuenta, 'delta', _delta, 'motivo', _motivo));
END;
$function$;

-- Fix abrir_debito_manual: replace closed card instead of failing on unique constraint
CREATE OR REPLACE FUNCTION public.abrir_debito_manual(_usuario_id uuid, _motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE u usuarios%ROWTYPE; td tarjetas_debito%ROWTYPE; num text; ncvv text; venc text;
BEGIN
  IF NOT (public.has_role('admin') OR public.has_role('trabajador')) THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO u FROM usuarios WHERE id = _usuario_id;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  SELECT * INTO td FROM tarjetas_debito WHERE usuario_id = u.id FOR UPDATE;
  IF td.id IS NOT NULL AND td.estado <> 'cerrada' THEN
    RAISE EXCEPTION 'Ya tiene tarjeta débito activa';
  END IF;
  num  := '4' || lpad((floor(random()*999999999999999)::bigint)::text, 15, '0');
  ncvv := lpad((floor(random()*999)::int)::text, 3, '0');
  venc := lpad((floor(random()*12)::int + 1)::text, 2, '0') || '/' || to_char(now() + interval '4 years', 'YY');
  IF td.id IS NULL THEN
    INSERT INTO tarjetas_debito(usuario_id, numero, cvv, vencimiento, estado, congelada)
      VALUES (u.id, num, ncvv, venc, 'activa', false);
  ELSE
    UPDATE tarjetas_debito SET numero=num, cvv=ncvv, vencimiento=venc, estado='activa', congelada=false
      WHERE id = td.id;
  END IF;
  PERFORM public.log_audit('ABRIR_DEBITO','tarjeta_debito', u.id, u.nombre, jsonb_build_object('motivo', _motivo));
END $function$;

-- Also: reabrir_cuenta should reactivate credit card if it was active/bloqueada before close (left cerrada)
-- We don't know previous state, so leave credit as cerrada (must be reissued via abrir_credito_manual).
