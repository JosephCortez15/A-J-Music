--  A&J MUSIC - Plataforma de musica
--  PARTE 2: FUNCIONES, PROCEDIMIENTOS Y TRIGGERS
--  Requisito: haber ejecutado antes 01_tablas.sql
--
--  Diferencia clave:
--    FUNCION       = calcula y DEVUELVE un valor. Se usa dentro de un SELECT.
--    PROCEDIMIENTO = EJECUTA un proceso de negocio completo. Se llama con CALL.
--    TRIGGER       = se dispara SOLO cuando pasa algo en una tabla (INSERT/UPDATE).


SET search_path TO oltp;


-- 1. FUNCIONES (devuelven un valor)

-- 1.1 Calcula la regalia de un artista: ingresos x porcentaje / 100
CREATE OR REPLACE FUNCTION fn_calcular_regalia(p_ingresos DECIMAL, p_porcentaje DECIMAL)
RETURNS DECIMAL
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN ROUND(p_ingresos * p_porcentaje / 100, 2);
END;
$$;

-- 1.2 Suma los pagos APROBADOS de un mes (los fallidos no cuentan)
CREATE OR REPLACE FUNCTION fn_ingresos_del_mes(p_periodo DATE)
RETURNS DECIMAL
LANGUAGE plpgsql
AS $$
DECLARE
    v_total DECIMAL(12,2);
BEGIN
    SELECT COALESCE(SUM(monto), 0) INTO v_total
      FROM pago
     WHERE estado = 'Aprobado'
       AND DATE_TRUNC('month', fecha_pago) = DATE_TRUNC('month', p_periodo);
    RETURN v_total;
END;
$$;

-- 1.3 Cuenta cuantas cuentas se registraron desde un mismo dispositivo
CREATE OR REPLACE FUNCTION fn_cuentas_por_dispositivo(p_huella VARCHAR)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_cantidad INT;
BEGIN
    SELECT COUNT(DISTINCT id_usuario) INTO v_cantidad
      FROM registro_dispositivo
     WHERE huella_hash = p_huella;
    RETURN v_cantidad;
END;
$$;


-- 2. TRIGGERS (se disparan solos)

-- 2.1 PAGO FALLIDO: si un pago llega como 'Fallido', la suscripcion se
--     suspende y la cuenta baja a Free. El usuario NO se elimina y el
--     cambio queda en historial_cuenta.
CREATE OR REPLACE FUNCTION fn_trg_pago_fallido()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    IF NEW.estado = 'Fallido' THEN
        -- De quien es la suscripcion de este pago?
        SELECT id_usuario INTO v_id_usuario
          FROM suscripcion
         WHERE id_suscripcion = NEW.id_suscripcion;

        UPDATE suscripcion SET estado = 'Suspendida'
         WHERE id_suscripcion = NEW.id_suscripcion;

        UPDATE usuario SET tipo_cuenta = 'Free'
         WHERE id_usuario = v_id_usuario;

        INSERT INTO historial_cuenta (id_usuario, id_pago, tipo_anterior, tipo_nuevo, motivo)
        VALUES (v_id_usuario, NEW.id_pago, 'Premium', 'Free',
                'Pago fallido, comprobante ' || NEW.nro_comprobante);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pago_fallido
AFTER INSERT OR UPDATE OF estado ON pago     -- al registrar o al cambiar el estado
FOR EACH ROW
EXECUTE FUNCTION fn_trg_pago_fallido();


-- 2.2 CONTROL DE CUENTAS MULTIPLES: antes de guardar un registro nuevo
--     - Mismo dispositivo con 2 cuentas  -> se BLOQUEA la tercera
--     - Misma IP con 2 o mas cuentas     -> solo se marca ALERTA
--       (familias, universidades y operadoras comparten IP)
CREATE OR REPLACE FUNCTION fn_trg_control_registro()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cuentas_ip INT;
BEGIN
    -- Regla 1: maximo 2 cuentas por dispositivo (usa la funcion 1.3)
    IF fn_cuentas_por_dispositivo(NEW.huella_hash) >= 2 THEN
        RAISE EXCEPTION 'Este dispositivo ya tiene 2 cuentas. No se permite crear otra.';
    END IF;

    -- Regla 2: si la IP ya tiene 2 o mas cuentas, se deja una alerta
    SELECT COUNT(DISTINCT id_usuario) INTO v_cuentas_ip
      FROM registro_dispositivo
     WHERE direccion_ip = NEW.direccion_ip;

    IF v_cuentas_ip >= 2 THEN
        NEW.alerta        := TRUE;
        NEW.motivo_alerta := 'IP con ' || v_cuentas_ip || ' cuentas ya registradas';
    END IF;

    RETURN NEW;   -- el registro se guarda (con o sin alerta)
END;
$$;

CREATE TRIGGER trg_control_registro
BEFORE INSERT ON registro_dispositivo        -- antes de guardar, para poder bloquear
FOR EACH ROW
EXECUTE FUNCTION fn_trg_control_registro();


-- 3. PROCEDIMIENTOS (procesos de negocio completos, se llaman con CALL)

-- 3.0 Registro de un perfil nuevo. Aplica la regla "un numero de celular = un perfil"
--     y registra el dispositivo (lo que dispara el control de cuentas multiples).
--     Si algo falla, NADA se guarda: ni el usuario ni su registro.
CREATE OR REPLACE PROCEDURE sp_registrar_usuario(
    p_nombre       VARCHAR,
    p_apellido     VARCHAR,
    p_email        VARCHAR,
    p_password     VARCHAR,
    p_id_pais      INT,
    p_telefono     VARCHAR,
    p_ip           VARCHAR,
    p_huella       VARCHAR,
    p_dispositivo  VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    -- Regla 1: el numero de celular es obligatorio y no puede tener otro perfil
    IF p_telefono IS NULL THEN
        RAISE EXCEPTION 'El numero de celular es obligatorio para crear un perfil';
    END IF;

    IF EXISTS (SELECT 1 FROM usuario WHERE telefono = p_telefono) THEN
        RAISE EXCEPTION 'El numero % ya tiene un perfil registrado', p_telefono;
    END IF;

    -- Crear el perfil (el celular queda verificado tras el codigo SMS)
    INSERT INTO usuario (nombre, apellido, email, password_hash, id_pais, telefono, telefono_verificado)
    VALUES (p_nombre, p_apellido, p_email, p_password, p_id_pais, p_telefono, TRUE)
    RETURNING id_usuario INTO v_id_usuario;

    -- Todo perfil nuevo empieza como Oyente
    INSERT INTO usuario_rol (id_usuario, id_rol) VALUES (v_id_usuario, 3);   -- 3 = Oyente

    -- Registrar el dispositivo: aqui se dispara trg_control_registro
    INSERT INTO registro_dispositivo (id_usuario, direccion_ip, huella_hash, tipo_dispositivo)
    VALUES (v_id_usuario, p_ip, p_huella, p_dispositivo);

    RAISE NOTICE 'Perfil % creado para %', v_id_usuario, p_email;
END;
$$;

-- 3.1 Un oyente se convierte en artista: crea sus datos comerciales,
--     le asigna el rol Artista y su contrato con el porcentaje acordado.
--     Conserva su mismo ID de usuario.
CREATE OR REPLACE PROCEDURE sp_convertir_en_artista(
    p_id_usuario        INT,
    p_nombre_artistico  VARCHAR,
    p_banco             VARCHAR,
    p_nro_cuenta        VARCHAR,
    p_porcentaje        DECIMAL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_titular VARCHAR(120);
BEGIN
    -- Validar que el usuario exista
    SELECT nombre || ' ' || apellido INTO v_titular
      FROM usuario WHERE id_usuario = p_id_usuario;

    IF v_titular IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_id_usuario;
    END IF;

    INSERT INTO artista (id_artista, nombre_artistico, banco, nro_cuenta, titular_cuenta)
    VALUES (p_id_usuario, p_nombre_artistico, p_banco, p_nro_cuenta, v_titular);

    INSERT INTO usuario_rol (id_usuario, id_rol)
    VALUES (p_id_usuario, 2);                          -- 2 = Artista

    INSERT INTO contrato (id_artista, fecha_inicio, porcentaje_regalia)
    VALUES (p_id_usuario, CURRENT_DATE, p_porcentaje);

    RAISE NOTICE 'El usuario % ahora es artista con % %% de regalias', p_id_usuario, p_porcentaje;
END;
$$;

-- 3.2 Cierre mensual: suma los ingresos del mes y genera una orden de pago
--     para cada artista con contrato vigente (usa las funciones 1.1 y 1.2).
CREATE OR REPLACE PROCEDURE sp_cierre_mensual(p_periodo DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio     DATE := DATE_TRUNC('month', p_periodo);   -- dia 1 del mes
    v_ingresos   DECIMAL(12,2);
    v_activos    INT;
    v_id_cierre  INT;
BEGIN
    -- 1) Ingresos aprobados del mes y suscriptores que pagaron
    v_ingresos := fn_ingresos_del_mes(v_inicio);

    SELECT COUNT(DISTINCT s.id_usuario) INTO v_activos
      FROM pago p
      JOIN suscripcion s ON s.id_suscripcion = p.id_suscripcion
     WHERE p.estado = 'Aprobado'
       AND DATE_TRUNC('month', p.fecha_pago) = v_inicio;

    -- 2) Registrar el cierre (si el mes ya se cerro, el UNIQUE lo impide)
    INSERT INTO cierre_mensual (periodo, total_suscriptores_activos, ingresos_totales)
    VALUES (v_inicio, v_activos, v_ingresos)
    RETURNING id_cierre INTO v_id_cierre;

    -- 3) Una orden de pago por cada artista con contrato vigente
    INSERT INTO orden_pago (id_cierre, id_artista, id_contrato, monto)
    SELECT v_id_cierre, id_artista, id_contrato,
           fn_calcular_regalia(v_ingresos, porcentaje_regalia)
      FROM contrato
     WHERE estado = 'Vigente';

    -- 4) Guardar el total de regalias del mes
    UPDATE cierre_mensual
       SET total_regalias = (SELECT SUM(monto) FROM orden_pago WHERE id_cierre = v_id_cierre)
     WHERE id_cierre = v_id_cierre;

    RAISE NOTICE 'Cierre de %: ingresos Bs %, % suscriptores', TO_CHAR(v_inicio, 'MM/YYYY'), v_ingresos, v_activos;
END;
$$;


-- 4. CONSULTAS DE NEGOCIO (para interpretar resultados)

-- 4.1 Que plan genera mas ingresos?
CREATE OR REPLACE VIEW v_ingresos_por_plan AS
SELECT pl.nombre AS plan,
       COUNT(p.id_pago) AS pagos_aprobados,
       SUM(p.monto)     AS ingresos_bs
  FROM pago p
  JOIN suscripcion s ON s.id_suscripcion = p.id_suscripcion
  JOIN plan pl       ON pl.id_plan = s.id_plan
 WHERE p.estado = 'Aprobado'
 GROUP BY pl.nombre;

-- 4.2 Cuanto cobra cada artista y con que porcentaje?
CREATE OR REPLACE VIEW v_regalias_por_artista AS
SELECT a.nombre_artistico,
       c.porcentaje_regalia,
       COALESCE(SUM(o.monto), 0) AS total_cobrado_bs
  FROM artista a
  JOIN contrato c        ON c.id_artista = a.id_artista AND c.estado = 'Vigente'
  LEFT JOIN orden_pago o ON o.id_artista = a.id_artista
 GROUP BY a.nombre_artistico, c.porcentaje_regalia;

-- 4.3 Que porcentaje de pagos falla? (riesgo de perder suscriptores)
CREATE OR REPLACE VIEW v_tasa_pagos_fallidos AS
SELECT COUNT(*) AS total_pagos,
       COUNT(*) FILTER (WHERE estado = 'Fallido') AS fallidos,
       ROUND(100.0 * COUNT(*) FILTER (WHERE estado = 'Fallido') / COUNT(*), 1) AS porcentaje_fallidos
  FROM pago;

-- 4.4 Que registros de cuentas son sospechosos?
CREATE OR REPLACE VIEW v_registros_con_alerta AS
SELECT r.id_usuario, u.nombre, r.direccion_ip, r.tipo_dispositivo, r.motivo_alerta
  FROM registro_dispositivo r
  JOIN usuario u ON u.id_usuario = r.id_usuario
 WHERE r.alerta = TRUE;


-- 5. DEMOSTRACION EN VIVO (ejecutar por partes, en orden)

-- PASO 1. Funciones: se usan dentro de un SELECT
SELECT fn_calcular_regalia(80, 5)        AS regalia_5_por_ciento,   -- 4.00
       fn_ingresos_del_mes('2026-10-01') AS ingresos_octubre;       -- 80.00

-- PASO 2. Procedimiento: Ana (usuario 5) se convierte en artista con 2,5 %
CALL sp_convertir_en_artista(5, 'Ana Flores Acustico', 'BNB', '2050011223', 2.50);
SELECT * FROM artista WHERE id_artista = 5;          -- mismo ID que como oyente

-- PASO 3. Trigger de pago fallido: llega un pago fallido de Carla (suscripcion 2)
INSERT INTO pago (id_suscripcion, nro_comprobante, fecha_pago, monto, metodo_pago, estado)
VALUES (2, 'CMP-0004', '2026-10-31 23:50', 15.00, 'Tarjeta', 'Fallido');

SELECT nombre, tipo_cuenta, estado FROM usuario WHERE id_usuario = 3;   -- Free, sigue Activo
SELECT * FROM historial_cuenta;                                          -- queda registrado

-- PASO 4. Registro de perfiles con control de cuentas
-- 4a) Marco se registra desde la casa de Luis y Carla (misma IP): se crea con ALERTA
CALL sp_registrar_usuario('Marco', 'Mamani', 'marco.mamani@mail.com', 'hash_007', 1,
                          '+59174567890', '181.115.4.20', 'huella_marco_cel', 'Android');
SELECT * FROM v_registros_con_alerta;

-- 4b) Pedro usa el celular de Luis: es la 2.a cuenta de ese dispositivo, se permite
CALL sp_registrar_usuario('Pedro', 'Mamani', 'pedro.mamani@mail.com', 'hash_008', 1,
                          '+59175678901', '45.12.1.1', 'huella_luis_cel', 'Android');

-- 4c) Numero repetido: el numero de Luis ya tiene perfil -> ERROR (descomentar)
-- CALL sp_registrar_usuario('Luis', 'Falso', 'luis.falso@mail.com', 'x', 1,
--                           '+59171234567', '45.12.1.2', 'huella_nueva', 'Web');

-- 4d) Tercera cuenta desde el celular de Luis -> ERROR y Rosa NO se crea (descomentar)
-- CALL sp_registrar_usuario('Rosa', 'Mamani', 'rosa.mamani@mail.com', 'x', 1,
--                           '+59176789012', '45.12.1.3', 'huella_luis_cel', 'Android');
-- SELECT * FROM usuario WHERE email = 'rosa.mamani@mail.com';   -- 0 filas

-- PASO 5. Procedimiento de cierre mensual de octubre
CALL sp_cierre_mensual('2026-10-01');
SELECT * FROM cierre_mensual;
SELECT * FROM v_regalias_por_artista;

-- Cerrar octubre otra vez da ERROR: un mes no se cierra dos veces (descomentar)
-- CALL sp_cierre_mensual('2026-10-01');

-- PASO 6. Consultas de negocio
SELECT * FROM v_ingresos_por_plan;
SELECT * FROM v_tasa_pagos_fallidos;
