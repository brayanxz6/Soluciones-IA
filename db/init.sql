-- Inicialización de la BD. Se ejecuta UNA vez (primer arranque del volumen)
-- como superusuario de PostgreSQL. Requiere psql >= 15 (\getenv).
-- La contraseña del rol de aplicación llega por la variable de entorno
-- APP_DB_PASSWORD, nunca escrita en este archivo.
\set ON_ERROR_STOP on
\getenv app_pwd APP_DB_PASSWORD

-- Tabla (propiedad del superusuario, NO del rol de aplicación)
CREATE TABLE IF NOT EXISTS clasificaciones (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mensaje     TEXT        NOT NULL CHECK (char_length(mensaje) BETWEEN 1 AND 500),
    categoria   TEXT        NOT NULL CHECK (categoria IN (
                    'feat','fix','docs','style','refactor','perf',
                    'test','build','ci','chore','revert')),
    motor       TEXT        NOT NULL CHECK (motor IN ('eco','ollama')),
    modelo      TEXT,
    confianza   REAL        CHECK (confianza IS NULL OR confianza BETWEEN 0 AND 1),
    latencia_ms DOUBLE PRECISION,
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_clasificaciones_creado_en
    ON clasificaciones (creado_en DESC);

-- Rol de aplicación: privilegios mínimos
CREATE ROLE app_ia WITH LOGIN PASSWORD :'app_pwd'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT
    CONNECTION LIMIT 10;
ALTER ROLE app_ia SET statement_timeout = '5s';

-- Cerrar permisos por defecto de PUBLIC
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Concesiones exactas: CONNECT, USAGE, SELECT, INSERT
SELECT format('GRANT CONNECT ON DATABASE %I TO app_ia', current_database()) \gexec
GRANT USAGE ON SCHEMA public TO app_ia;
GRANT SELECT, INSERT ON TABLE clasificaciones TO app_ia;
-- Nota: la columna id es IDENTITY; PostgreSQL no exige privilegios sobre su
-- secuencia interna para INSERT, por lo que no se concede USAGE sobre ella.
-- Sin UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ni CREATE.
