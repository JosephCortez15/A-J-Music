
DROP SCHEMA IF EXISTS oltp CASCADE;   -- limpia todo lo anterior
CREATE SCHEMA oltp;                   -- esquema propio del sistema transaccional
SET search_path TO oltp;              -- trabajar dentro de ese esquema


-- Catálogo de países (evita repetir el nombre del país en cada usuario)
CREATE TABLE pais (
    id_pais     SERIAL       PRIMARY KEY,
    codigo_iso  VARCHAR(2)   NOT NULL UNIQUE,      -- BO, PE, AR...
    nombre      VARCHAR(60)  NOT NULL UNIQUE
);

-- Roles permitidos en el sistema
CREATE TABLE rol (
    id_rol       SERIAL        PRIMARY KEY,
    nombre       VARCHAR(150)  NOT NULL UNIQUE
                 CHECK (nombre IN ('Administrador', 'Artista', 'Oyente')),
    descripcion  VARCHAR(150)
);

-- Cuenta base de cada persona. Nunca se borra: se cambia su estado.
CREATE TABLE usuario (
    id_usuario           SERIAL        PRIMARY KEY,
    nombre               VARCHAR(60)   NOT NULL,
    apellido             VARCHAR(60)   NOT NULL,
    email                VARCHAR(120)  NOT NULL UNIQUE,   -- sin cuentas duplicadas
    password_hash        VARCHAR(255)  NOT NULL,          -- nunca la contraseña real
    id_pais              INT           NOT NULL REFERENCES pais(id_pais),
    tipo_cuenta          VARCHAR(50)   NOT NULL DEFAULT 'Free'
                         CHECK (tipo_cuenta IN ('Free', 'Premium')),
    estado               VARCHAR(20)   NOT NULL DEFAULT 'Activo'
                         CHECK (estado IN ('Activo', 'Suspendido', 'Inactivo')),
    fecha_registro       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    telefono             VARCHAR(20)   UNIQUE,
    telefono_verificado  BOOLEAN       NOT NULL DEFAULT FALSE,
    email_verificado     BOOLEAN       NOT NULL DEFAULT FALSE
);

-- Relacion N:M: una persona puede tener varios roles (ej. Oyente y Artista)
CREATE TABLE usuario_rol (
    id_usuario        INT        NOT NULL REFERENCES usuario(id_usuario),
    id_rol            INT        NOT NULL REFERENCES rol(id_rol),
    fecha_asignacion  TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_usuario, id_rol)                -- el mismo rol no se repite
);

-- Datos comerciales del artista. Su PK es la misma que la del usuario,
-- asi el oyente que se vuelve artista conserva su ID (relacion 1 a 0..1).
CREATE TABLE artista (
    id_artista        INT           PRIMARY KEY REFERENCES usuario(id_usuario),
    nombre_artistico  VARCHAR(100)  NOT NULL UNIQUE,
    banco             VARCHAR(80)   NOT NULL,
    nro_cuenta        VARCHAR(30)   NOT NULL UNIQUE,
    titular_cuenta    VARCHAR(120)  NOT NULL,
    fecha_alta        DATE          NOT NULL DEFAULT CURRENT_DATE
);

-- Desde donde se registra cada cuenta (control de cuentas multiples).
-- La huella del dispositivo se guarda como hash, no como datos crudos.
CREATE TABLE registro_dispositivo (
    id_registro       SERIAL        PRIMARY KEY,
    id_usuario        INT           NOT NULL REFERENCES usuario(id_usuario),
    direccion_ip      VARCHAR(45)   NOT NULL,       -- 45 caracteres cubre IPv4 e IPv6
    huella_hash       VARCHAR(64)   NOT NULL,
    tipo_dispositivo  VARCHAR(20)   NOT NULL
                      CHECK (tipo_dispositivo IN ('Web', 'Android', 'iOS')),
    alerta            BOOLEAN       NOT NULL DEFAULT FALSE,   -- la marca el trigger
    motivo_alerta     VARCHAR(150),
    fecha             TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- 2. DINERO QUE ENTRA: planes, suscripciones y pagos

CREATE TABLE plan (
    id_plan         SERIAL         PRIMARY KEY,
    nombre          VARCHAR(30)    NOT NULL UNIQUE,
    precio_mensual  DECIMAL(10,2)  NOT NULL CHECK (precio_mensual > 0),
    duracion_dias   INT            NOT NULL CHECK (duracion_dias > 0),
    activo          BOOLEAN        NOT NULL DEFAULT TRUE
);

CREATE TABLE suscripcion (
    id_suscripcion  SERIAL       PRIMARY KEY,
    id_usuario      INT          NOT NULL REFERENCES usuario(id_usuario),
    id_plan         INT          NOT NULL REFERENCES plan(id_plan),
    fecha_inicio    DATE         NOT NULL,
    fecha_fin       DATE         NOT NULL,
    estado          VARCHAR(60)  NOT NULL DEFAULT 'Activa'
                    CHECK (estado IN ('Activa', 'Suspendida', 'Cancelada', 'Vencida')),
    CHECK (fecha_fin > fecha_inicio)
);
-- Regla: un usuario solo puede tener UNA suscripcion activa a la vez
CREATE UNIQUE INDEX ux_una_suscripcion_activa
    ON suscripcion (id_usuario) WHERE estado = 'Activa';

-- Cada pago con comprobante, fecha y monto
CREATE TABLE pago (
    id_pago          SERIAL         PRIMARY KEY,
    id_suscripcion   INT            NOT NULL REFERENCES suscripcion(id_suscripcion),
    nro_comprobante  VARCHAR(30)    NOT NULL UNIQUE,   -- el mismo pago no entra dos veces
    fecha_pago       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    monto            DECIMAL(10,2)  NOT NULL CHECK (monto > 0),
    metodo_pago      VARCHAR(20)    NOT NULL
                     CHECK (metodo_pago IN ('Tarjeta', 'QR', 'Transferencia')),
    estado           VARCHAR(60)    NOT NULL DEFAULT 'Pendiente'
                     CHECK (estado IN ('Pendiente', 'Aprobado', 'Fallido'))
);

-- Bitacora de cambios Free <-> Premium (la llena el trigger de pago fallido)
CREATE TABLE historial_cuenta (
    id_historial   SERIAL        PRIMARY KEY,
    id_usuario     INT           NOT NULL REFERENCES usuario(id_usuario),
    id_pago        INT           REFERENCES pago(id_pago),   -- opcional (0..1)
    tipo_anterior  VARCHAR(10)   NOT NULL,
    tipo_nuevo     VARCHAR(10)   NOT NULL,
    motivo         VARCHAR(150)  NOT NULL,
    fecha_cambio   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

=
-- 3. DINERO QUE SALE: contratos y regalias

-- El contrato fija el porcentaje de regalias del artista
CREATE TABLE contrato (
    id_contrato         SERIAL        PRIMARY KEY,
    id_artista          INT           NOT NULL REFERENCES artista(id_artista),
    fecha_inicio        DATE          NOT NULL,
    fecha_fin           DATE,
    porcentaje_regalia  DECIMAL(5,2)  NOT NULL
                        CHECK (porcentaje_regalia > 0 AND porcentaje_regalia <= 100),
    estado              VARCHAR(50)   NOT NULL DEFAULT 'Vigente'
                        CHECK (estado IN ('Vigente', 'Finalizado'))
);
-- Regla: un artista solo puede tener UN contrato vigente
CREATE UNIQUE INDEX ux_un_contrato_vigente
    ON contrato (id_artista) WHERE estado = 'Vigente';

-- Una fila por mes (el periodo es siempre el día 1 del mes)
CREATE TABLE cierre_mensual (
    id_cierre                   SERIAL         PRIMARY KEY,
    periodo                     DATE           NOT NULL UNIQUE,   -- un mes no se cierra dos veces
    total_suscriptores_activos  INT            NOT NULL,
    ingresos_totales            DECIMAL(12,2)  NOT NULL,
    total_regalias              DECIMAL(12,2)  NOT NULL DEFAULT 0,
    fecha_ejecucion             TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Lo que se le debe a cada artista en cada cierre
CREATE TABLE orden_pago (
    id_orden          SERIAL         PRIMARY KEY,
    id_cierre         INT            NOT NULL REFERENCES cierre_mensual(id_cierre),
    id_artista        INT            NOT NULL REFERENCES artista(id_artista),
    id_contrato       INT            NOT NULL REFERENCES contrato(id_contrato),
    monto             DECIMAL(12,2)  NOT NULL CHECK (monto >= 0),
    estado            VARCHAR(60)    NOT NULL DEFAULT 'Pendiente'
                      CHECK (estado IN ('Pendiente', 'Pagada', 'Anulada')),
    fecha_generacion  TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (id_cierre, id_artista)   -- un artista no cobra dos veces el mismo mes
);


-- 4. DATOS DE PRUEBA

INSERT INTO pais (codigo_iso, nombre) VALUES
    ('BO', 'Bolivia'), ('PE', 'Peru'), ('AR', 'Argentina'), ('CL', 'Chile');

INSERT INTO rol (nombre, descripcion) VALUES
    ('Administrador', 'Gestiona la plataforma y los cierres contables'),
    ('Artista',       'Publica musica y recibe regalias'),
    ('Oyente',        'Escucha musica en modalidad Free o Premium');

INSERT INTO plan (nombre, precio_mensual, duracion_dias) VALUES
    ('Premium Individual', 25.00, 30),
    ('Premium Estudiante', 15.00, 30),
    ('Premium Familiar',   40.00, 30);

-- Usuarios 1 a 7 (Ana todavia no verifico su celular)
INSERT INTO usuario (nombre, apellido, email, password_hash, id_pais, tipo_cuenta, telefono, telefono_verificado, email_verificado) VALUES
    ('Admin',   'Sistema',   'admin@ajmusic.bo',       'hash_admin', 1, 'Free',    '+59170000001', TRUE,  TRUE),
    ('Luis',    'Mamani',    'luis.mamani@mail.com',   'hash_001',   1, 'Premium', '+59171234567', TRUE,  TRUE),
    ('Carla',   'Quispe',    'carla.quispe@mail.com',  'hash_002',   1, 'Premium', '+59172345678', TRUE,  TRUE),
    ('Diego',   'Rojas',     'diego.rojas@mail.com',   'hash_003',   2, 'Premium', '+51987654321', TRUE,  TRUE),
    ('Ana',     'Flores',    'ana.flores@mail.com',    'hash_004',   3, 'Free',    NULL,           FALSE, TRUE),
    ('Jorge',   'Condori',   'jorge.condori@mail.com', 'hash_005',   1, 'Free',    '+59173456789', TRUE,  TRUE),
    ('Valeria', 'Gutierrez', 'valeria.gtz@mail.com',   'hash_006',   4, 'Free',    '+56912345678', TRUE,  TRUE);

-- Todos son oyentes; el usuario 1 ademas es administrador
INSERT INTO usuario_rol (id_usuario, id_rol)
SELECT id_usuario, 3 FROM usuario;                            -- 3 = Oyente
INSERT INTO usuario_rol (id_usuario, id_rol) VALUES (1, 1);   -- 1 = Administrador

-- Jorge (6) y Valeria (7) ya son artistas, con su mismo ID de oyente
INSERT INTO artista (id_artista, nombre_artistico, banco, nro_cuenta, titular_cuenta, fecha_alta) VALUES
    (6, 'Jorge C. y Los Andinos', 'Banco Union',     '1000234567', 'Jorge Condori',     '2026-09-01'),
    (7, 'Vale Indie',             'Banco Mercantil', '4010098765', 'Valeria Gutierrez', '2026-09-15');
INSERT INTO usuario_rol (id_usuario, id_rol) VALUES (6, 2), (7, 2);   -- 2 = Artista
INSERT INTO contrato (id_artista, fecha_inicio, porcentaje_regalia) VALUES
    (6, '2026-09-01', 5.00),
    (7, '2026-09-15', 3.50);

-- Donde se registro cada cuenta (Luis y Carla viven juntos: misma IP)
INSERT INTO registro_dispositivo (id_usuario, direccion_ip, huella_hash, tipo_dispositivo, fecha) VALUES
    (1, '200.87.10.5',   'huella_admin_pc',     'Web',     '2026-08-01 09:00'),
    (2, '181.115.4.20',  'huella_luis_cel',     'Android', '2026-09-20 18:30'),
    (3, '181.115.4.20',  'huella_carla_laptop', 'Web',     '2026-09-20 19:10'),
    (4, '190.43.77.12',  'huella_diego_iphone', 'iOS',     '2026-09-25 12:00'),
    (5, '186.27.140.3',  'huella_ana_pc',       'Web',     '2026-09-28 21:45'),
    (6, '200.87.33.71',  'huella_jorge_cel',    'Android', '2026-08-15 10:20'),
    (7, '191.126.9.200', 'huella_vale_pc',      'Web',     '2026-09-10 16:05');

-- Suscripciones de octubre 2026
INSERT INTO suscripcion (id_usuario, id_plan, fecha_inicio, fecha_fin) VALUES
    (2, 1, '2026-10-01', '2026-10-31'),   -- Luis: Individual
    (3, 2, '2026-10-01', '2026-10-31'),   -- Carla: Estudiante
    (4, 3, '2026-10-01', '2026-10-31');   -- Diego: Familiar

-- Pagos de octubre: todos aprobados
INSERT INTO pago (id_suscripcion, nro_comprobante, fecha_pago, monto, metodo_pago, estado) VALUES
    (1, 'CMP-0001', '2026-10-01 10:15', 25.00, 'QR',      'Aprobado'),
    (2, 'CMP-0002', '2026-10-01 11:40', 15.00, 'Tarjeta', 'Aprobado'),
    (3, 'CMP-0003', '2026-10-02 09:05', 40.00, 'Tarjeta', 'Aprobado');


-- 5. PRUEBAS DE INTEGRIDAD (descomentar una por una: todas deben dar ERROR)

-- a) Email duplicado
-- INSERT INTO usuario (nombre, apellido, email, password_hash, id_pais)
-- VALUES ('Luis', 'Copia', 'luis.mamani@mail.com', 'x', 1);

-- b) Telefono repetido (un numero = una cuenta)
-- INSERT INTO usuario (nombre, apellido, email, password_hash, id_pais, telefono)
-- VALUES ('Luis', 'Falso', 'luis.falso@mail.com', 'x', 1, '+59171234567');

-- c) Segunda suscripcion activa para el mismo usuario
-- INSERT INTO suscripcion (id_usuario, id_plan, fecha_inicio, fecha_fin)
-- VALUES (2, 2, '2026-10-05', '2026-11-04');

-- d) Pago con monto negativo
-- INSERT INTO pago (id_suscripcion, nro_comprobante, monto, metodo_pago)
-- VALUES (1, 'CMP-ERROR', -10, 'QR');

-- e) Borrar un usuario que tiene suscripciones (la FK lo impide)
-- DELETE FROM usuario WHERE id_usuario = 2;
